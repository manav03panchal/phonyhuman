"""Tests for linear-cli.py — parse_identifier, _validate_endpoint, _find_api_key,
argument dispatch, and graphql error handling."""

import importlib
import json
import os
import sys
import tempfile
import textwrap
import unittest
import urllib.error
from io import BytesIO
from unittest import mock


# ---------------------------------------------------------------------------
# Import helpers: linear-cli.py uses a hyphen so we can't import it normally.
# We load it as a module via importlib.
# ---------------------------------------------------------------------------

def _load_module():
    """Import linear-cli.py as a module named 'linear_cli'."""
    cli_path = os.path.join(os.path.dirname(__file__), "linear-cli.py")
    spec = importlib.util.spec_from_file_location("linear_cli", cli_path)
    mod = importlib.util.module_from_spec(spec)
    # Patch env so module-level _validate_endpoint and _find_api_key don't die
    with mock.patch.dict(os.environ, {
        "LINEAR_API_KEY": "test-key",
        "LINEAR_ENDPOINT": "https://api.linear.app/graphql",
    }):
        spec.loader.exec_module(mod)
    return mod


cli = _load_module()


# ---------------------------------------------------------------------------
# Tests for parse_identifier
# ---------------------------------------------------------------------------

class TestParseIdentifier(unittest.TestCase):
    """Tests for parse_identifier()."""

    def test_valid_team_number(self):
        result = cli.parse_identifier("HUM-5")
        self.assertEqual(result, ("HUM", 5))

    def test_valid_alphanumeric_team_key(self):
        result = cli.parse_identifier("ENG2-42")
        self.assertEqual(result, ("ENG2", 42))

    def test_single_letter_team_key(self):
        result = cli.parse_identifier("X-1")
        self.assertEqual(result, ("X", 1))

    def test_uuid_returns_none(self):
        uuid = "a4be1bbc-1802-456e-99d4-7c2671ea4360"
        result = cli.parse_identifier(uuid)
        self.assertIsNone(result)

    def test_no_hyphen_returns_none(self):
        result = cli.parse_identifier("abc123")
        self.assertIsNone(result)

    def test_invalid_lowercase_team_key_dies(self):
        with self.assertRaises(SystemExit):
            cli.parse_identifier("hum-5")

    def test_invalid_starts_with_digit_dies(self):
        with self.assertRaises(SystemExit):
            cli.parse_identifier("2ENG-5")

    def test_non_numeric_number_returns_none(self):
        # "HUM-abc" — rsplit gives ("HUM", "abc"), "abc".isdigit() is False → None
        result = cli.parse_identifier("HUM-abc")
        self.assertIsNone(result)

    def test_large_issue_number(self):
        result = cli.parse_identifier("PROJ-99999")
        self.assertEqual(result, ("PROJ", 99999))

    def test_zero_issue_number(self):
        result = cli.parse_identifier("HUM-0")
        self.assertEqual(result, ("HUM", 0))


# ---------------------------------------------------------------------------
# Tests for _validate_endpoint
# ---------------------------------------------------------------------------

class TestValidateEndpoint(unittest.TestCase):
    """Tests for _validate_endpoint()."""

    def test_valid_default_endpoint(self):
        result = cli._validate_endpoint("https://api.linear.app/graphql")
        self.assertEqual(result, "https://api.linear.app/graphql")

    def test_valid_bare_domain(self):
        result = cli._validate_endpoint("https://linear.app/graphql")
        self.assertEqual(result, "https://linear.app/graphql")

    def test_valid_subdomain(self):
        result = cli._validate_endpoint("https://staging.linear.app/graphql")
        self.assertEqual(result, "https://staging.linear.app/graphql")

    def test_rejects_http(self):
        with self.assertRaises(SystemExit):
            cli._validate_endpoint("http://api.linear.app/graphql")

    def test_rejects_wrong_domain(self):
        with self.assertRaises(SystemExit):
            cli._validate_endpoint("https://evil.example.com/graphql")

    def test_rejects_domain_suffix_attack(self):
        # "notlinear.app" should be rejected
        with self.assertRaises(SystemExit):
            cli._validate_endpoint("https://notlinear.app/graphql")

    def test_rejects_subdomain_suffix_attack(self):
        # "evil.notlinear.app" should be rejected
        with self.assertRaises(SystemExit):
            cli._validate_endpoint("https://evil.notlinear.app/graphql")

    def test_rejects_ftp_scheme(self):
        with self.assertRaises(SystemExit):
            cli._validate_endpoint("ftp://api.linear.app/graphql")

    def test_rejects_empty_scheme(self):
        with self.assertRaises(SystemExit):
            cli._validate_endpoint("://api.linear.app/graphql")


# ---------------------------------------------------------------------------
# Tests for _find_api_key
# ---------------------------------------------------------------------------

class TestFindApiKey(unittest.TestCase):
    """Tests for _find_api_key()."""

    def test_env_var_takes_precedence(self):
        with mock.patch.dict(os.environ, {"LINEAR_API_KEY": "env-key"}):
            result = cli._find_api_key()
        self.assertEqual(result, "env-key")

    def test_missing_env_var_and_no_toml_returns_empty(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            # Run in a temp dir with no .toml files
            with tempfile.TemporaryDirectory() as tmpdir:
                orig_cwd = os.getcwd()
                try:
                    os.chdir(tmpdir)
                    # Remove LINEAR_API_KEY if present
                    env = os.environ.copy()
                    env.pop("LINEAR_API_KEY", None)
                    with mock.patch.dict(os.environ, env, clear=True):
                        result = cli._find_api_key()
                finally:
                    os.chdir(orig_cwd)
        self.assertEqual(result, "")

    def test_symphony_toml_fallback(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            toml_path = os.path.join(tmpdir, "symphony.toml")
            with open(toml_path, "w") as f:
                f.write('[linear]\napi_key = "symphony-key"\n')

            orig_cwd = os.getcwd()
            try:
                os.chdir(tmpdir)
                env = os.environ.copy()
                env.pop("LINEAR_API_KEY", None)
                with mock.patch.dict(os.environ, env, clear=True):
                    result = cli._find_api_key()
            finally:
                os.chdir(orig_cwd)
        self.assertEqual(result, "symphony-key")

    def test_phonyhuman_toml_fallback(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            toml_path = os.path.join(tmpdir, "phonyhuman.toml")
            with open(toml_path, "w") as f:
                f.write('[linear]\napi_key = "phonyhuman-key"\n')

            orig_cwd = os.getcwd()
            try:
                os.chdir(tmpdir)
                env = os.environ.copy()
                env.pop("LINEAR_API_KEY", None)
                with mock.patch.dict(os.environ, env, clear=True):
                    result = cli._find_api_key()
            finally:
                os.chdir(orig_cwd)
        self.assertEqual(result, "phonyhuman-key")

    def test_arbitrary_toml_ignored(self):
        """Arbitrary .toml files must not be read (HUM-132)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            toml_path = os.path.join(tmpdir, "evil.toml")
            with open(toml_path, "w") as f:
                f.write('[linear]\napi_key = "evil-key"\n')

            orig_cwd = os.getcwd()
            try:
                os.chdir(tmpdir)
                env = os.environ.copy()
                env.pop("LINEAR_API_KEY", None)
                with mock.patch.dict(os.environ, env, clear=True):
                    result = cli._find_api_key()
            finally:
                os.chdir(orig_cwd)
        self.assertEqual(result, "")

    def test_symphony_toml_preferred_over_phonyhuman(self):
        """symphony.toml is checked first."""
        with tempfile.TemporaryDirectory() as tmpdir:
            with open(os.path.join(tmpdir, "symphony.toml"), "w") as f:
                f.write('[linear]\napi_key = "sym-key"\n')
            with open(os.path.join(tmpdir, "phonyhuman.toml"), "w") as f:
                f.write('[linear]\napi_key = "ph-key"\n')

            orig_cwd = os.getcwd()
            try:
                os.chdir(tmpdir)
                env = os.environ.copy()
                env.pop("LINEAR_API_KEY", None)
                with mock.patch.dict(os.environ, env, clear=True):
                    result = cli._find_api_key()
            finally:
                os.chdir(orig_cwd)
        self.assertEqual(result, "sym-key")


# ---------------------------------------------------------------------------
# Tests for main() argument dispatch
# ---------------------------------------------------------------------------

class TestMainDispatch(unittest.TestCase):
    """Tests for main() argument routing."""

    def test_no_args_prints_usage_and_exits(self):
        with mock.patch.object(sys, "argv", ["linear-cli"]):
            with self.assertRaises(SystemExit) as ctx:
                cli.main()
            self.assertEqual(ctx.exception.code, 1)

    def test_unknown_command_prints_usage_and_exits(self):
        with mock.patch.object(sys, "argv", ["linear-cli", "bogus"]):
            with self.assertRaises(SystemExit) as ctx:
                cli.main()
            self.assertEqual(ctx.exception.code, 1)

    def test_comment_insufficient_args_exits(self):
        with mock.patch.object(sys, "argv", ["linear-cli", "comment", "ID"]):
            with self.assertRaises(SystemExit) as ctx:
                cli.main()
            self.assertEqual(ctx.exception.code, 1)

    def test_get_issue_insufficient_args_exits(self):
        with mock.patch.object(sys, "argv", ["linear-cli", "get-issue"]):
            with self.assertRaises(SystemExit) as ctx:
                cli.main()
            self.assertEqual(ctx.exception.code, 1)

    def test_set_state_insufficient_args_exits(self):
        with mock.patch.object(sys, "argv", ["linear-cli", "set-state", "HUM-1"]):
            with self.assertRaises(SystemExit) as ctx:
                cli.main()
            self.assertEqual(ctx.exception.code, 1)

    @mock.patch.object(cli, "cmd_comment")
    def test_comment_dispatches_correctly(self, mock_cmd):
        with mock.patch.object(sys, "argv", ["linear-cli", "comment", "ID-1", "body text"]):
            cli.main()
        mock_cmd.assert_called_once_with("ID-1", "body text")

    @mock.patch.object(cli, "cmd_edit_comment")
    def test_edit_comment_dispatches_correctly(self, mock_cmd):
        with mock.patch.object(sys, "argv", ["linear-cli", "edit-comment", "cid", "new body"]):
            cli.main()
        mock_cmd.assert_called_once_with("cid", "new body")

    @mock.patch.object(cli, "cmd_get_issue")
    def test_get_issue_dispatches_correctly(self, mock_cmd):
        with mock.patch.object(sys, "argv", ["linear-cli", "get-issue", "HUM-42"]):
            cli.main()
        mock_cmd.assert_called_once_with("HUM-42")

    @mock.patch.object(cli, "cmd_get_comments")
    def test_get_comments_dispatches_correctly(self, mock_cmd):
        with mock.patch.object(sys, "argv", ["linear-cli", "get-comments", "HUM-42"]):
            cli.main()
        mock_cmd.assert_called_once_with("HUM-42")

    @mock.patch.object(cli, "cmd_set_state")
    def test_set_state_dispatches_correctly(self, mock_cmd):
        with mock.patch.object(sys, "argv", ["linear-cli", "set-state", "HUM-1", "Done"]):
            cli.main()
        mock_cmd.assert_called_once_with("HUM-1", "Done")

    @mock.patch.object(cli, "cmd_attach_url")
    def test_attach_url_without_title(self, mock_cmd):
        with mock.patch.object(sys, "argv", ["linear-cli", "attach-url", "HUM-1", "https://example.com"]):
            cli.main()
        mock_cmd.assert_called_once_with("HUM-1", "https://example.com", None)

    @mock.patch.object(cli, "cmd_attach_url")
    def test_attach_url_with_title(self, mock_cmd):
        with mock.patch.object(sys, "argv", ["linear-cli", "attach-url", "HUM-1", "https://example.com", "My PR"]):
            cli.main()
        mock_cmd.assert_called_once_with("HUM-1", "https://example.com", "My PR")

    @mock.patch.object(cli, "cmd_graphql")
    def test_graphql_without_variables(self, mock_cmd):
        with mock.patch.object(sys, "argv", ["linear-cli", "graphql", "{ viewer { id } }"]):
            cli.main()
        mock_cmd.assert_called_once_with("{ viewer { id } }", None)

    @mock.patch.object(cli, "cmd_graphql")
    def test_graphql_with_variables(self, mock_cmd):
        with mock.patch.object(sys, "argv", ["linear-cli", "graphql", "query($id: String!){ issue(id: $id) { id } }", '{"id": "abc"}']):
            cli.main()
        mock_cmd.assert_called_once_with("query($id: String!){ issue(id: $id) { id } }", '{"id": "abc"}')


# ---------------------------------------------------------------------------
# Tests for graphql() error handling
# ---------------------------------------------------------------------------

def _make_http_error(code, body="", headers=None):
    """Create a urllib.error.HTTPError for testing."""
    if headers is None:
        headers = {}
    fp = BytesIO(body.encode())
    err = urllib.error.HTTPError(
        url="https://api.linear.app/graphql",
        code=code,
        msg=f"HTTP {code}",
        hdrs=headers,
        fp=fp,
    )
    # Monkey-patch headers for .get() access
    err.headers = headers
    return err


class _FakeHeaders(dict):
    """Dict subclass with a .get() method matching http.client.HTTPMessage."""
    def get(self, key, default=None):
        return super().get(key, default)


class TestGraphqlErrorHandling(unittest.TestCase):
    """Tests for graphql() HTTP and GraphQL error paths."""

    def _patch_api_key(self):
        return mock.patch.object(cli, "API_KEY", "test-key")

    def test_dies_when_api_key_missing(self):
        with mock.patch.object(cli, "API_KEY", ""):
            with self.assertRaises(SystemExit):
                cli.graphql("{ viewer { id } }")

    def test_http_401_dies_with_auth_message(self):
        err = _make_http_error(401, "Unauthorized", _FakeHeaders())
        with self._patch_api_key(), \
             mock.patch("urllib.request.urlopen", side_effect=err):
            with self.assertRaises(SystemExit) as ctx:
                cli.graphql("{ viewer { id } }")
            self.assertEqual(ctx.exception.code, 1)

    def test_http_429_dies_with_rate_limit_message(self):
        headers = _FakeHeaders({"Retry-After": "30"})
        err = _make_http_error(429, "Too Many Requests", headers)
        with self._patch_api_key(), \
             mock.patch("urllib.request.urlopen", side_effect=err):
            with self.assertRaises(SystemExit) as ctx:
                cli.graphql("{ viewer { id } }")
            self.assertEqual(ctx.exception.code, 1)

    def test_http_500_dies_with_body(self):
        err = _make_http_error(500, "Internal Server Error", _FakeHeaders())
        with self._patch_api_key(), \
             mock.patch("urllib.request.urlopen", side_effect=err):
            with self.assertRaises(SystemExit):
                cli.graphql("{ viewer { id } }")

    def test_network_error_dies(self):
        url_err = urllib.error.URLError("Connection refused")
        with self._patch_api_key(), \
             mock.patch("urllib.request.urlopen", side_effect=url_err):
            with self.assertRaises(SystemExit):
                cli.graphql("{ viewer { id } }")

    def test_timeout_error_dies(self):
        with self._patch_api_key(), \
             mock.patch("urllib.request.urlopen", side_effect=TimeoutError):
            with self.assertRaises(SystemExit):
                cli.graphql("{ viewer { id } }")

    def test_graphql_auth_error_dies(self):
        resp_data = {
            "errors": [{
                "message": "Invalid token",
                "extensions": {"code": "AUTHENTICATION_ERROR"},
            }]
        }
        resp_bytes = json.dumps(resp_data).encode()
        fake_resp = BytesIO(resp_bytes)
        fake_resp.read = lambda: resp_bytes

        with self._patch_api_key(), \
             mock.patch("urllib.request.urlopen") as mock_open:
            mock_open.return_value.__enter__ = mock.Mock(return_value=fake_resp)
            mock_open.return_value.__exit__ = mock.Mock(return_value=False)
            with self.assertRaises(SystemExit):
                cli.graphql("{ viewer { id } }")

    def test_graphql_rate_limited_error_dies(self):
        resp_data = {
            "errors": [{
                "message": "Rate limited",
                "extensions": {"code": "RATELIMITED"},
            }]
        }
        resp_bytes = json.dumps(resp_data).encode()
        fake_resp = BytesIO(resp_bytes)
        fake_resp.read = lambda: resp_bytes

        with self._patch_api_key(), \
             mock.patch("urllib.request.urlopen") as mock_open:
            mock_open.return_value.__enter__ = mock.Mock(return_value=fake_resp)
            mock_open.return_value.__exit__ = mock.Mock(return_value=False)
            with self.assertRaises(SystemExit):
                cli.graphql("{ viewer { id } }")

    def test_graphql_generic_error_dies(self):
        resp_data = {
            "errors": [{
                "message": "Something went wrong",
                "extensions": {},
            }]
        }
        resp_bytes = json.dumps(resp_data).encode()
        fake_resp = BytesIO(resp_bytes)
        fake_resp.read = lambda: resp_bytes

        with self._patch_api_key(), \
             mock.patch("urllib.request.urlopen") as mock_open:
            mock_open.return_value.__enter__ = mock.Mock(return_value=fake_resp)
            mock_open.return_value.__exit__ = mock.Mock(return_value=False)
            with self.assertRaises(SystemExit):
                cli.graphql("{ viewer { id } }")

    def test_successful_graphql_returns_data(self):
        resp_data = {"data": {"viewer": {"id": "user-123"}}}
        resp_bytes = json.dumps(resp_data).encode()
        fake_resp = BytesIO(resp_bytes)
        fake_resp.read = lambda: resp_bytes

        with self._patch_api_key(), \
             mock.patch("urllib.request.urlopen") as mock_open:
            mock_open.return_value.__enter__ = mock.Mock(return_value=fake_resp)
            mock_open.return_value.__exit__ = mock.Mock(return_value=False)
            result = cli.graphql("{ viewer { id } }")
        self.assertEqual(result, resp_data)


# ---------------------------------------------------------------------------
# Tests for resolve_issue_id
# ---------------------------------------------------------------------------

class TestResolveIssueId(unittest.TestCase):
    """Tests for resolve_issue_id()."""

    def test_uuid_passthrough(self):
        uuid = "a4be1bbc-1802-456e-99d4-7c2671ea4360"
        result = cli.resolve_issue_id(uuid)
        self.assertEqual(result, uuid)

    @mock.patch.object(cli, "graphql")
    def test_human_id_resolves(self, mock_gql):
        mock_gql.side_effect = [
            # First call: find team
            {"data": {"teams": {"nodes": [{"id": "team-1"}]}}},
            # Second call: find issue
            {"data": {"issues": {"nodes": [{"id": "issue-uuid", "identifier": "HUM-5"}]}}},
        ]
        result = cli.resolve_issue_id("HUM-5")
        self.assertEqual(result, "issue-uuid")
        self.assertEqual(mock_gql.call_count, 2)

    @mock.patch.object(cli, "graphql")
    def test_team_not_found_dies(self, mock_gql):
        mock_gql.return_value = {"data": {"teams": {"nodes": []}}}
        with self.assertRaises(SystemExit):
            cli.resolve_issue_id("NOPE-1")

    @mock.patch.object(cli, "graphql")
    def test_issue_not_found_dies(self, mock_gql):
        mock_gql.side_effect = [
            {"data": {"teams": {"nodes": [{"id": "team-1"}]}}},
            {"data": {"issues": {"nodes": []}}},
        ]
        with self.assertRaises(SystemExit):
            cli.resolve_issue_id("HUM-99999")


if __name__ == "__main__":
    unittest.main()
