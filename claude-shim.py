#!/usr/bin/env python3
"""
claude-shim: An agent server protocol shim that drives Claude Code CLI.

Speaks JSON-RPC 2.0 on stdin/stdout so Symphony treats it as an agent server,
but internally spawns `claude` CLI using the user's Claude Code Max subscription.

Usage in WORKFLOW.md:
  codex:
    command: "python3 /path/to/claude-shim.py"
"""

import json
import os
import re
import signal
import subprocess
import sys
import threading
import urllib.request
import urllib.error
import uuid


# ---------------------------------------------------------------------------
# Logging (stderr only — stdout is the JSON-RPC channel)
# ---------------------------------------------------------------------------

def log(msg):
    print(f"[claude-shim] {msg}", file=sys.stderr, flush=True)


def log_error(msg):
    print(f"[claude-shim] ERROR: {msg}", file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------
# JSON-RPC helpers
# ---------------------------------------------------------------------------

def send(payload):
    """Send a JSON-RPC message to Symphony via stdout."""
    line = json.dumps(payload, separators=(",", ":")) + "\n"
    sys.stdout.write(line)
    sys.stdout.flush()


def send_result(req_id, result):
    send({"id": req_id, "result": result})


def send_error(req_id, code, message):
    send({"id": req_id, "error": {"code": code, "message": message}})


def send_notification(method, params=None):
    msg = {"method": method}
    if params is not None:
        msg["params"] = params
    send(msg)


# ---------------------------------------------------------------------------
# Linear GraphQL tool (mirrors Symphony's DynamicTool)
# ---------------------------------------------------------------------------

def execute_linear_graphql(arguments):
    """Execute a GraphQL query against Linear using Symphony's auth."""
    api_key = os.environ.get("LINEAR_API_KEY", "")
    if not api_key:
        return {
            "success": False,
            "contentItems": [{"type": "inputText", "text": json.dumps({
                "error": {"message": "LINEAR_API_KEY not set in environment."}
            })}],
        }

    if isinstance(arguments, str):
        query = arguments
        variables = {}
    elif isinstance(arguments, dict):
        query = arguments.get("query", "")
        variables = arguments.get("variables") or {}
    else:
        return {
            "success": False,
            "contentItems": [{"type": "inputText", "text": json.dumps({
                "error": {"message": "Invalid arguments for linear_graphql."}
            })}],
        }

    if not query.strip():
        return {
            "success": False,
            "contentItems": [{"type": "inputText", "text": json.dumps({
                "error": {"message": "linear_graphql requires a non-empty query."}
            })}],
        }

    endpoint = os.environ.get("LINEAR_ENDPOINT", "https://api.linear.app/graphql")
    body = json.dumps({"query": query, "variables": variables}).encode()
    req = urllib.request.Request(
        endpoint,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": api_key,
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode())
            errors = data.get("errors", [])
            return {
                "success": not bool(errors),
                "contentItems": [{"type": "inputText", "text": json.dumps(data, indent=2)}],
            }
    except Exception as exc:
        return {
            "success": False,
            "contentItems": [{"type": "inputText", "text": json.dumps({
                "error": {"message": f"Linear GraphQL request failed: {exc}"}
            })}],
        }


# ---------------------------------------------------------------------------
# Rate limit / usage cap detection helpers
# ---------------------------------------------------------------------------

_RATE_LIMIT_PATTERNS = [
    "hit your limit",
    "hit the limit",
    "rate limit",
    "rate_limit",
    "usage limit",
    "try again later",
    "try again in",
    "too many requests",
    "429",
]

_USAGE_CAP_PATTERNS = [
    "usage cap",
    "subscription limit",
]

_RETRY_AFTER_RE = re.compile(
    r"try again in\s+(\d+)\s*(hour|minute|second|hr|min|sec)s?",
    re.IGNORECASE,
)


def is_rate_limit(text):
    """Return True if text contains rate-limit indicators."""
    lower = text.lower()
    return any(p in lower for p in _RATE_LIMIT_PATTERNS)


def is_usage_cap(text):
    """Return True if text indicates a subscription-level usage cap."""
    lower = text.lower()
    # Explicit usage-cap phrases
    if any(p in lower for p in _USAGE_CAP_PATTERNS):
        return True
    # "hit your limit" combined with a reset-time reference
    if ("hit your limit" in lower or "hit the limit" in lower):
        if _RETRY_AFTER_RE.search(text) or "reset" in lower or "tomorrow" in lower:
            return True
    return False


def parse_retry_after(text):
    """Extract a retry-after duration in seconds from error text, or None."""
    m = _RETRY_AFTER_RE.search(text)
    if not m:
        return None
    value = int(m.group(1))
    unit = m.group(2).lower()
    if unit.startswith("hour") or unit == "hr":
        return value * 3600
    if unit.startswith("min"):
        return value * 60
    if unit.startswith("sec"):
        return value
    return None


def classify_error(text):
    """Classify error text into (error_type, is_global, retry_after).

    Returns one of:
        ("usage_cap", True, retry_after_seconds_or_None)
        ("rate_limit", False, retry_after_seconds_or_None)
        ("agent_error", False, None)
    """
    retry_after = parse_retry_after(text)
    if is_usage_cap(text):
        return "usage_cap", True, retry_after
    if is_rate_limit(text):
        return "rate_limit", False, retry_after
    return "agent_error", False, None


# ---------------------------------------------------------------------------
# Claude Code runner
# ---------------------------------------------------------------------------

class ClaudeRunner:
    """Runs a single Claude Code CLI turn in a workspace directory."""

    def __init__(self, cwd, prompt, on_event):
        self.cwd = cwd
        self.prompt = prompt
        self.on_event = on_event  # callback(event_dict)
        self.proc = None
        self.errors_seen = []

    def run(self):
        """Spawn claude CLI, stream events, return (success, result_or_error)."""
        cmd = [
            "claude",
            "-p", self.prompt,
            "--output-format", "stream-json",
            "--dangerously-skip-permissions",
            "--verbose",
        ]

        # Build a clean environment for the Claude subprocess.
        # Remove CLAUDECODE to avoid "nested session" detection.
        env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}

        # Inject OpenTelemetry environment variables unless explicitly disabled.
        if os.environ.get("SYMPHONY_OTEL_DISABLED") != "1":
            otel_port = os.environ.get("SYMPHONY_OTEL_PORT", "4317")
            env["CLAUDE_CODE_ENABLE_TELEMETRY"] = "1"
            env["OTEL_METRICS_EXPORTER"] = "otlp"
            env["OTEL_LOGS_EXPORTER"] = "otlp"
            env["OTEL_EXPORTER_OTLP_ENDPOINT"] = f"http://127.0.0.1:{otel_port}"
            env["OTEL_METRIC_EXPORT_INTERVAL"] = "5000"
            env["OTEL_LOGS_EXPORT_INTERVAL"] = "2000"

        log(f"Spawning Claude in {self.cwd}")
        try:
            self.proc = subprocess.Popen(
                cmd,
                cwd=self.cwd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                stdin=subprocess.DEVNULL,
                env=env,
            )
        except FileNotFoundError:
            return False, "claude CLI not found in PATH"
        except Exception as exc:
            return False, f"Failed to spawn claude: {exc}"

        # Read stderr in a background thread so it doesn't block
        stderr_lines = []
        def drain_stderr():
            for line in self.proc.stderr:
                text = line.decode("utf-8", errors="replace").rstrip()
                if text:
                    stderr_lines.append(text)
                    log(f"claude stderr: {text}")

        t = threading.Thread(target=drain_stderr, daemon=True)
        t.start()

        # Stream stdout (stream-json: one JSON object per line)
        last_result = None
        for raw_line in self.proc.stdout:
            text = raw_line.decode("utf-8", errors="replace").rstrip()
            if not text:
                continue
            try:
                event = json.loads(text)
            except json.JSONDecodeError:
                log(f"claude non-json output: {text}")
                continue

            event_type = event.get("type", "")

            # Track error events during streaming
            if event_type == "error":
                self.errors_seen.append(event)

            # Capture the final result message
            if event_type == "result":
                last_result = event
            elif event_type == "assistant":
                # Forward assistant messages as notifications
                self.on_event({
                    "type": "assistant_message",
                    "content": event.get("message", ""),
                })

            # Also emit raw for observability
            self.on_event({"type": "claude_event", "event": event})

        t.join(timeout=5)
        rc = self.proc.wait()
        self.stderr_lines = stderr_lines

        if rc != 0:
            err_text = "\n".join(stderr_lines[-10:]) if stderr_lines else f"exit code {rc}"
            return False, f"claude exited with code {rc}: {err_text}"

        if last_result:
            return True, last_result
        return True, {"type": "result", "result": "completed"}

    def kill(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()


# ---------------------------------------------------------------------------
# Session state
# ---------------------------------------------------------------------------

class Session:
    def __init__(self):
        self.thread_id = None
        self.thread_cwd = None
        self.dynamic_tools = []
        self.current_runner = None
        self.turn_thread = None

    def handle_initialize(self, req_id, params):
        log("initialize")
        send_result(req_id, {
            "capabilities": {"experimentalApi": True},
            "serverInfo": {
                "name": "claude-shim",
                "version": "1.0.0",
            },
        })

    def handle_initialized(self, params):
        log("initialized notification received")

    def handle_thread_start(self, req_id, params):
        self.thread_id = str(uuid.uuid4())
        self.thread_cwd = params.get("cwd", os.getcwd())
        self.dynamic_tools = params.get("dynamicTools", [])
        log(f"thread/start → thread_id={self.thread_id} cwd={self.thread_cwd}")
        send_result(req_id, {"thread": {"id": self.thread_id}})

    def handle_turn_start(self, req_id, params):
        turn_id = str(uuid.uuid4())
        cwd = params.get("cwd", self.thread_cwd or os.getcwd())
        input_items = params.get("input", [])
        title = params.get("title", "")

        # Extract prompt text from input items
        prompt_parts = []
        for item in input_items:
            if isinstance(item, dict) and item.get("type") == "text":
                prompt_parts.append(item.get("text", ""))
        prompt = "\n\n".join(prompt_parts)

        if not prompt.strip():
            send_error(req_id, -32602, "Empty prompt")
            return

        log(f"turn/start → turn_id={turn_id} title={title}")

        # Respond immediately with turn ID (Codex protocol: ack, then stream)
        send_result(req_id, {"turn": {"id": turn_id}})

        # Run Claude in a background thread — the main loop continues
        # reading stdin for tool call responses, etc.
        def run_turn():
            def on_event(evt):
                # Forward Claude events as notifications so Symphony can log them
                params = {"event": evt}
                # Forward usage from raw Claude event if present
                if evt.get("type") == "claude_event":
                    raw_event = evt.get("event", {})
                    if isinstance(raw_event, dict) and "usage" in raw_event:
                        params["usage"] = raw_event["usage"]
                send_notification("item/message", params)

            runner = ClaudeRunner(cwd, prompt, on_event)
            self.current_runner = runner

            success, result = runner.run()
            self.current_runner = None

            if success:
                # Check if the result indicates an error despite exit code 0
                result_is_error = False
                error_text = ""

                if isinstance(result, dict) and result.get("is_error", False):
                    result_is_error = True
                    error_text = result.get("result", "") or str(result)

                # Check streaming errors for rate-limit signals
                if not result_is_error and runner.errors_seen:
                    combined = " ".join(
                        e.get("error", {}).get("message", "") if isinstance(e.get("error"), dict)
                        else str(e.get("error", ""))
                        for e in runner.errors_seen
                    )
                    if is_rate_limit(combined) or is_usage_cap(combined):
                        result_is_error = True
                        error_text = combined

                # Edge case: last_result is None but stderr has limit text
                if not result_is_error and result == {"type": "result", "result": "completed"}:
                    stderr_text = "\n".join(getattr(runner, "stderr_lines", []))
                    if stderr_text and (is_rate_limit(stderr_text) or is_usage_cap(stderr_text)):
                        result_is_error = True
                        error_text = stderr_text

                if result_is_error:
                    error_type, is_global, retry_after = classify_error(error_text)
                    log_error(f"turn result has error (type={error_type}): {error_text[:200]}")
                    fail_params = {
                        "turnId": turn_id,
                        "threadId": self.thread_id,
                        "error": error_text,
                        "error_type": error_type,
                        "is_global": is_global,
                    }
                    if retry_after is not None:
                        fail_params["retry_after"] = retry_after
                    send_notification("turn/failed", fail_params)
                else:
                    log("turn completed successfully")
                    completed_params = {
                        "turnId": turn_id,
                        "threadId": self.thread_id,
                    }
                    # Extract usage metrics from result
                    if isinstance(result, dict):
                        raw_usage = result.get("usage")
                        if isinstance(raw_usage, dict):
                            completed_params["usage"] = {
                                "input_tokens": raw_usage.get("input_tokens", 0),
                                "output_tokens": raw_usage.get("output_tokens", 0),
                                "cache_read_input_tokens": raw_usage.get("cache_read_input_tokens", 0),
                                "cache_creation_input_tokens": raw_usage.get("cache_creation_input_tokens", 0),
                                "total_tokens": raw_usage.get("input_tokens", 0) + raw_usage.get("output_tokens", 0),
                            }
                        if result.get("cost_usd") is not None:
                            completed_params["cost_usd"] = result["cost_usd"]
                        if result.get("duration_ms") is not None:
                            completed_params["duration_ms"] = result["duration_ms"]
                        if result.get("model") is not None:
                            completed_params["model"] = result["model"]
                        if result.get("num_turns") is not None:
                            completed_params["num_turns"] = result["num_turns"]
                    send_notification("turn/completed", completed_params)
            else:
                log_error(f"turn failed: {result}")
                send_notification("turn/failed", {
                    "turnId": turn_id,
                    "threadId": self.thread_id,
                    "error": str(result),
                })

        self.turn_thread = threading.Thread(target=run_turn, daemon=True)
        self.turn_thread.start()

    def handle_tool_call(self, req_id, params):
        """Handle Symphony sending us a tool call to execute."""
        tool_name = (
            params.get("tool")
            or params.get("name")
            or ""
        )
        arguments = params.get("arguments", {})

        log(f"tool call: {tool_name}")

        if tool_name == "linear_graphql":
            result = execute_linear_graphql(arguments)
        else:
            result = {
                "success": False,
                "contentItems": [{"type": "inputText", "text": json.dumps({
                    "error": {"message": f"Unsupported tool: {tool_name}"}
                })}],
            }

        send_result(req_id, result)

    def shutdown(self):
        if self.current_runner:
            self.current_runner.kill()
        if self.turn_thread and self.turn_thread.is_alive():
            self.turn_thread.join(timeout=10)


# ---------------------------------------------------------------------------
# Main RPC loop
# ---------------------------------------------------------------------------

def main():
    session = Session()

    def handle_signal(signum, frame):
        log(f"Received signal {signum}, shutting down")
        session.shutdown()
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    log("claude-shim started, waiting for JSON-RPC messages on stdin")

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue

        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            log(f"ignoring non-JSON input: {line[:200]}")
            continue

        method = msg.get("method")
        req_id = msg.get("id")
        params = msg.get("params", {})

        if method == "initialize":
            session.handle_initialize(req_id, params)

        elif method == "initialized":
            session.handle_initialized(params)

        elif method == "thread/start":
            session.handle_thread_start(req_id, params)

        elif method == "turn/start":
            session.handle_turn_start(req_id, params)

        elif method == "item/tool/call":
            session.handle_tool_call(req_id, params)

        elif req_id is not None:
            # Unknown request — ack it to avoid blocking Symphony
            log(f"unknown request method={method}, acking")
            send_result(req_id, {})

        else:
            # Unknown notification — ignore
            log(f"ignoring notification method={method}")

    log("stdin closed, shutting down")
    session.shutdown()


if __name__ == "__main__":
    main()
