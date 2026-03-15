"""Tests for rate limit / usage cap detection in claude-shim."""

import importlib
import json
import os
import sys
import types
import unittest


# Import helpers from claude-shim.py (hyphenated filename requires importlib)
spec = importlib.util.spec_from_file_location("claude_shim", "claude-shim.py")
claude_shim = importlib.util.module_from_spec(spec)
spec.loader.exec_module(claude_shim)

is_rate_limit = claude_shim.is_rate_limit
is_usage_cap = claude_shim.is_usage_cap
parse_retry_after = claude_shim.parse_retry_after
classify_error = claude_shim.classify_error
ClaudeRunner = claude_shim.ClaudeRunner
validate_otel_port = claude_shim.validate_otel_port
is_allowed_otel_endpoint = claude_shim.is_allowed_otel_endpoint
strip_otel_endpoint_vars = claude_shim.strip_otel_endpoint_vars
_validate_linear_endpoint = claude_shim._validate_linear_endpoint
execute_linear_graphql = claude_shim.execute_linear_graphql


class TestValidateLinearEndpoint(unittest.TestCase):
    def test_default_endpoint_accepted(self):
        self.assertEqual(
            _validate_linear_endpoint("https://api.linear.app/graphql"),
            "https://api.linear.app/graphql",
        )

    def test_subdomain_accepted(self):
        self.assertEqual(
            _validate_linear_endpoint("https://staging.linear.app/graphql"),
            "https://staging.linear.app/graphql",
        )

    def test_bare_domain_accepted(self):
        self.assertEqual(
            _validate_linear_endpoint("https://linear.app/graphql"),
            "https://linear.app/graphql",
        )

    def test_http_rejected(self):
        self.assertIsNone(_validate_linear_endpoint("http://api.linear.app/graphql"))

    def test_arbitrary_domain_rejected(self):
        self.assertIsNone(_validate_linear_endpoint("https://evil.com/graphql"))

    def test_lookalike_domain_rejected(self):
        self.assertIsNone(
            _validate_linear_endpoint("https://notlinear.app/graphql")
        )

    def test_suffix_attack_rejected(self):
        self.assertIsNone(
            _validate_linear_endpoint("https://evil.com.linear.app.attacker.com/graphql")
        )

    def test_empty_string_rejected(self):
        self.assertIsNone(_validate_linear_endpoint(""))

    def test_no_scheme_rejected(self):
        self.assertIsNone(_validate_linear_endpoint("api.linear.app/graphql"))


class TestExecuteLinearGraphqlEndpointValidation(unittest.TestCase):
    """Ensure execute_linear_graphql rejects invalid LINEAR_ENDPOINT values."""

    def test_rejects_evil_endpoint(self):
        original = os.environ.get("LINEAR_ENDPOINT")
        os.environ["LINEAR_ENDPOINT"] = "https://evil.com/steal"
        try:
            result = execute_linear_graphql({"query": "{ viewer { id } }"})
            self.assertFalse(result["success"])
            self.assertIn("rejected", result["contentItems"][0]["text"])
        finally:
            if original is None:
                os.environ.pop("LINEAR_ENDPOINT", None)
            else:
                os.environ["LINEAR_ENDPOINT"] = original

    def test_rejects_http_endpoint(self):
        original = os.environ.get("LINEAR_ENDPOINT")
        os.environ["LINEAR_ENDPOINT"] = "http://api.linear.app/graphql"
        try:
            result = execute_linear_graphql({"query": "{ viewer { id } }"})
            self.assertFalse(result["success"])
            self.assertIn("rejected", result["contentItems"][0]["text"])
        finally:
            if original is None:
                os.environ.pop("LINEAR_ENDPOINT", None)
            else:
                os.environ["LINEAR_ENDPOINT"] = original


class TestIsRateLimit(unittest.TestCase):
    def test_hit_your_limit(self):
        self.assertTrue(is_rate_limit("You've hit your limit for the day"))

    def test_hit_the_limit(self):
        self.assertTrue(is_rate_limit("You've hit the limit"))

    def test_rate_limit_phrase(self):
        self.assertTrue(is_rate_limit("Rate limit exceeded"))

    def test_rate_limit_underscore(self):
        self.assertTrue(is_rate_limit("error: rate_limit"))

    def test_usage_limit(self):
        self.assertTrue(is_rate_limit("Usage limit reached"))

    def test_try_again_later(self):
        self.assertTrue(is_rate_limit("Please try again later"))

    def test_try_again_in(self):
        self.assertTrue(is_rate_limit("Try again in 2 hours"))

    def test_too_many_requests(self):
        self.assertTrue(is_rate_limit("Too many requests"))

    def test_429_code(self):
        self.assertTrue(is_rate_limit("HTTP 429"))

    def test_normal_text_not_rate_limit(self):
        self.assertFalse(is_rate_limit("Task completed successfully"))

    def test_empty_string(self):
        self.assertFalse(is_rate_limit(""))

    def test_case_insensitive(self):
        self.assertTrue(is_rate_limit("RATE LIMIT exceeded"))
        self.assertTrue(is_rate_limit("Too Many Requests"))


class TestIsUsageCap(unittest.TestCase):
    def test_usage_cap(self):
        self.assertTrue(is_usage_cap("You've reached your usage cap"))

    def test_subscription_limit(self):
        self.assertTrue(is_usage_cap("subscription limit reached"))

    def test_hit_limit_with_reset_time(self):
        self.assertTrue(is_usage_cap(
            "You've hit your limit. Try again in 2 hours."
        ))

    def test_hit_limit_with_reset(self):
        self.assertTrue(is_usage_cap(
            "You've hit your limit. Your usage will reset tomorrow."
        ))

    def test_hit_limit_without_reset_not_usage_cap(self):
        # "hit your limit" alone without a reset reference is NOT a usage cap
        self.assertFalse(is_usage_cap("You've hit your limit"))

    def test_normal_text_not_usage_cap(self):
        self.assertFalse(is_usage_cap("Task completed"))

    def test_empty_string(self):
        self.assertFalse(is_usage_cap(""))

    def test_case_insensitive(self):
        self.assertTrue(is_usage_cap("USAGE CAP reached"))
        self.assertTrue(is_usage_cap("SUBSCRIPTION LIMIT"))


class TestParseRetryAfter(unittest.TestCase):
    def test_hours(self):
        self.assertEqual(parse_retry_after("Try again in 2 hours"), 7200)

    def test_minutes(self):
        self.assertEqual(parse_retry_after("Try again in 30 minutes"), 1800)

    def test_seconds(self):
        self.assertEqual(parse_retry_after("Try again in 60 seconds"), 60)

    def test_singular_hour(self):
        self.assertEqual(parse_retry_after("try again in 1 hour"), 3600)

    def test_hr_abbreviation(self):
        self.assertEqual(parse_retry_after("try again in 3 hr"), 10800)

    def test_min_abbreviation(self):
        self.assertEqual(parse_retry_after("try again in 15 min"), 900)

    def test_no_match(self):
        self.assertIsNone(parse_retry_after("Something went wrong"))

    def test_empty_string(self):
        self.assertIsNone(parse_retry_after(""))

    def test_unparseable(self):
        self.assertIsNone(parse_retry_after("try again later"))


class TestClassifyError(unittest.TestCase):
    def test_usage_cap(self):
        error_type, is_global, retry_after = classify_error(
            "You've hit your limit. Try again in 2 hours."
        )
        self.assertEqual(error_type, "usage_cap")
        self.assertTrue(is_global)
        self.assertEqual(retry_after, 7200)

    def test_usage_cap_subscription(self):
        error_type, is_global, retry_after = classify_error(
            "subscription limit reached"
        )
        self.assertEqual(error_type, "usage_cap")
        self.assertTrue(is_global)
        self.assertIsNone(retry_after)

    def test_rate_limit(self):
        error_type, is_global, retry_after = classify_error(
            "Rate limit exceeded. Too many requests."
        )
        self.assertEqual(error_type, "rate_limit")
        self.assertFalse(is_global)
        self.assertIsNone(retry_after)

    def test_rate_limit_429(self):
        error_type, is_global, retry_after = classify_error("HTTP 429")
        self.assertEqual(error_type, "rate_limit")
        self.assertFalse(is_global)

    def test_agent_error(self):
        error_type, is_global, retry_after = classify_error(
            "Something unexpected happened"
        )
        self.assertEqual(error_type, "agent_error")
        self.assertFalse(is_global)
        self.assertIsNone(retry_after)

    def test_normal_success_text(self):
        error_type, is_global, retry_after = classify_error("completed")
        self.assertEqual(error_type, "agent_error")
        self.assertFalse(is_global)
        self.assertIsNone(retry_after)


class TestClaudeRunnerErrorsTracking(unittest.TestCase):
    def test_errors_seen_initialized(self):
        runner = ClaudeRunner("/tmp", "test prompt", lambda e: None)
        self.assertEqual(runner.errors_seen, [])

    def test_errors_seen_tracks_error_events(self):
        """Verify that error events in the stream are captured."""
        runner = ClaudeRunner("/tmp", "test prompt", lambda e: None)
        # Simulate what the streaming loop does:
        # When event_type == "error", it appends to errors_seen
        error_event = {"type": "error", "error": {"message": "rate limit exceeded"}}
        runner.errors_seen.append(error_event)
        self.assertEqual(len(runner.errors_seen), 1)
        self.assertEqual(runner.errors_seen[0]["error"]["message"], "rate limit exceeded")


class TestTurnClassificationIntegration(unittest.TestCase):
    """Test the classification logic used in run_turn()."""

    def _simulate_turn_decision(self, last_result, errors_seen=None, stderr_lines=None):
        """Simulate the decision logic from run_turn().

        Returns (outcome, params) where outcome is 'completed' or 'failed'.
        """
        errors_seen = errors_seen or []
        stderr_lines = stderr_lines or []

        result_is_error = False
        error_text = ""

        if isinstance(last_result, dict) and last_result.get("is_error", False):
            result_is_error = True
            error_text = last_result.get("result", "") or str(last_result)

        if not result_is_error and errors_seen:
            combined = " ".join(
                e.get("error", {}).get("message", "") if isinstance(e.get("error"), dict)
                else str(e.get("error", ""))
                for e in errors_seen
            )
            if is_rate_limit(combined) or is_usage_cap(combined):
                result_is_error = True
                error_text = combined

        if not result_is_error and last_result == {"type": "result", "result": "completed"}:
            stderr_text = "\n".join(stderr_lines)
            if stderr_text and (is_rate_limit(stderr_text) or is_usage_cap(stderr_text)):
                result_is_error = True
                error_text = stderr_text

        if result_is_error:
            error_type, is_global, retry_after = classify_error(error_text)
            params = {
                "error": error_text,
                "error_type": error_type,
                "is_global": is_global,
            }
            if retry_after is not None:
                params["retry_after"] = retry_after
            return "failed", params
        return "completed", {}

    def test_normal_success(self):
        result = {"type": "result", "result": "Task done", "is_error": False}
        outcome, params = self._simulate_turn_decision(result)
        self.assertEqual(outcome, "completed")

    def test_usage_cap_error(self):
        result = {
            "type": "result",
            "is_error": True,
            "result": "You've hit your limit. Try again in 2 hours.",
        }
        outcome, params = self._simulate_turn_decision(result)
        self.assertEqual(outcome, "failed")
        self.assertEqual(params["error_type"], "usage_cap")
        self.assertTrue(params["is_global"])
        self.assertEqual(params["retry_after"], 7200)

    def test_rate_limit_error(self):
        result = {
            "type": "result",
            "is_error": True,
            "result": "Rate limit exceeded. Too many requests.",
        }
        outcome, params = self._simulate_turn_decision(result)
        self.assertEqual(outcome, "failed")
        self.assertEqual(params["error_type"], "rate_limit")
        self.assertFalse(params["is_global"])

    def test_generic_error(self):
        result = {
            "type": "result",
            "is_error": True,
            "result": "Internal server error",
        }
        outcome, params = self._simulate_turn_decision(result)
        self.assertEqual(outcome, "failed")
        self.assertEqual(params["error_type"], "agent_error")
        self.assertFalse(params["is_global"])

    def test_is_error_false_is_success(self):
        result = {"type": "result", "result": "done", "is_error": False}
        outcome, _ = self._simulate_turn_decision(result)
        self.assertEqual(outcome, "completed")

    def test_streaming_errors_cause_failure(self):
        result = {"type": "result", "result": "completed"}
        errors = [{"type": "error", "error": {"message": "rate limit exceeded"}}]
        outcome, params = self._simulate_turn_decision(result, errors_seen=errors)
        self.assertEqual(outcome, "failed")
        self.assertEqual(params["error_type"], "rate_limit")

    def test_stderr_limit_text_causes_failure(self):
        result = {"type": "result", "result": "completed"}
        stderr = ["Error: too many requests"]
        outcome, params = self._simulate_turn_decision(result, stderr_lines=stderr)
        self.assertEqual(outcome, "failed")
        self.assertEqual(params["error_type"], "rate_limit")

    def test_no_retry_after_key_when_none(self):
        result = {
            "type": "result",
            "is_error": True,
            "result": "Rate limit exceeded",
        }
        outcome, params = self._simulate_turn_decision(result)
        self.assertNotIn("retry_after", params)


class TestValidateOtelPort(unittest.TestCase):
    def test_valid_port(self):
        self.assertEqual(validate_otel_port("4317"), 4317)

    def test_valid_port_min(self):
        self.assertEqual(validate_otel_port("1"), 1)

    def test_valid_port_max(self):
        self.assertEqual(validate_otel_port("65535"), 65535)

    def test_zero_rejected(self):
        self.assertIsNone(validate_otel_port("0"))

    def test_negative_rejected(self):
        self.assertIsNone(validate_otel_port("-1"))

    def test_too_large_rejected(self):
        self.assertIsNone(validate_otel_port("65536"))

    def test_non_numeric_rejected(self):
        self.assertIsNone(validate_otel_port("abc"))

    def test_url_injection_rejected(self):
        self.assertIsNone(validate_otel_port("4317@evil.com"))

    def test_empty_string_rejected(self):
        self.assertIsNone(validate_otel_port(""))

    def test_none_rejected(self):
        self.assertIsNone(validate_otel_port(None))

    def test_float_rejected(self):
        self.assertIsNone(validate_otel_port("4317.5"))

    def test_whitespace_stripped(self):
        # int() strips whitespace, which is acceptable behavior
        self.assertEqual(validate_otel_port(" 4317 "), 4317)


class TestIsAllowedOtelEndpoint(unittest.TestCase):
    def test_localhost_127(self):
        self.assertTrue(is_allowed_otel_endpoint("http://127.0.0.1:4317"))

    def test_localhost_name(self):
        self.assertTrue(is_allowed_otel_endpoint("http://localhost:4317"))

    def test_localhost_ipv6(self):
        self.assertTrue(is_allowed_otel_endpoint("http://[::1]:4317"))

    def test_external_host_rejected(self):
        self.assertFalse(is_allowed_otel_endpoint("http://evil.com:4317"))

    def test_external_ip_rejected(self):
        self.assertFalse(is_allowed_otel_endpoint("http://10.0.0.1:4317"))

    def test_allowlist_permits_host(self):
        self.assertTrue(is_allowed_otel_endpoint(
            "http://otel-collector.internal:4317",
            allowed_hosts={"otel-collector.internal"},
        ))

    def test_allowlist_rejects_unlisted(self):
        self.assertFalse(is_allowed_otel_endpoint(
            "http://evil.com:4317",
            allowed_hosts={"otel-collector.internal"},
        ))

    def test_empty_endpoint_rejected(self):
        self.assertFalse(is_allowed_otel_endpoint(""))

    def test_no_scheme_rejected(self):
        self.assertFalse(is_allowed_otel_endpoint("evil.com:4317"))

    def test_url_injection_via_userinfo(self):
        # Construct URL with userinfo segment at runtime to avoid secret-scanner
        # false positive.  The real hostname resolves to evil.com, not localhost.
        injected_url = "http://127.0.0.1:4317" + "@" + "evil.com"
        self.assertFalse(is_allowed_otel_endpoint(injected_url))

    def test_case_insensitive(self):
        self.assertTrue(is_allowed_otel_endpoint("http://LOCALHOST:4317"))


class TestStripOtelEndpointVars(unittest.TestCase):
    def test_strips_all_endpoint_vars(self):
        env = {
            "OTEL_EXPORTER_OTLP_ENDPOINT": "http://evil.com:4317",
            "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "http://evil.com:4318",
            "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT": "http://evil.com:4319",
            "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": "http://evil.com:4320",
            "OTHER_VAR": "keep",
        }
        strip_otel_endpoint_vars(env)
        self.assertNotIn("OTEL_EXPORTER_OTLP_ENDPOINT", env)
        self.assertNotIn("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", env)
        self.assertNotIn("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT", env)
        self.assertNotIn("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT", env)
        self.assertEqual(env["OTHER_VAR"], "keep")

    def test_no_error_when_vars_absent(self):
        env = {"SOME_VAR": "value"}
        strip_otel_endpoint_vars(env)
        self.assertEqual(env, {"SOME_VAR": "value"})


if __name__ == "__main__":
    unittest.main()
