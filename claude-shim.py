#!/usr/bin/env python3
"""
claude-shim: A Codex app-server protocol shim that drives Claude Code CLI.

Speaks JSON-RPC 2.0 on stdin/stdout so Symphony treats it as a Codex app-server,
but internally spawns `claude` CLI using the user's Claude Code Max subscription.

Usage in WORKFLOW.md:
  codex:
    command: "python3 /path/to/claude-shim.py"
"""

import json
import os
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
# Claude Code runner
# ---------------------------------------------------------------------------

class ClaudeRunner:
    """Runs a single Claude Code CLI turn in a workspace directory."""

    def __init__(self, cwd, prompt, on_event):
        self.cwd = cwd
        self.prompt = prompt
        self.on_event = on_event  # callback(event_dict)
        self.proc = None

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
                send_notification("item/message", {"event": evt})

            runner = ClaudeRunner(cwd, prompt, on_event)
            self.current_runner = runner

            success, result = runner.run()
            self.current_runner = None

            if success:
                log("turn completed successfully")
                send_notification("turn/completed", {
                    "turnId": turn_id,
                    "threadId": self.thread_id,
                })
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
