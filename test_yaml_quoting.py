"""Tests for YAML quoting in workflow generation (bin/phonyhuman)."""

import unittest
import yaml


def yaml_quote(value):
    """Quote a string for safe YAML embedding (handles :, #, {, etc.)."""
    special_chars = (':', '#', '{', '}', '[', ']', ',', '&', '*', '?', '|',
                     '-', '<', '>', '=', '!', '%', '@', '`', '"', "'")
    s = str(value)
    if any(c in s for c in special_chars) or s != s.strip() or not s:
        return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'
    return s


def yaml_list(items):
    return "\n".join(f"    - {yaml_quote(s)}" for s in items)


def build_workflow_yaml(active_states, terminal_states, ws_root, shim_path, slug="test"):
    """Reproduce the YAML generation from bin/phonyhuman."""
    return f"""---
tracker:
  kind: linear
  project_slug: {yaml_quote(slug)}
  active_states:
{yaml_list(active_states)}
  terminal_states:
{yaml_list(terminal_states)}
workspace:
  root: {yaml_quote(ws_root)}
agent_server:
  command: {yaml_quote("python3 " + shim_path)}
---
"""


def parse_first_doc(yaml_str):
    return list(yaml.safe_load_all(yaml_str))[0]


class TestYamlQuote(unittest.TestCase):
    def test_plain_string_no_special(self):
        self.assertEqual(yaml_quote("Todo"), "Todo")

    def test_colon_gets_quoted(self):
        self.assertEqual(yaml_quote("In Progress: Active"), '"In Progress: Active"')

    def test_hash_gets_quoted(self):
        self.assertEqual(yaml_quote("Review #2"), '"Review #2"')

    def test_braces_get_quoted(self):
        self.assertEqual(yaml_quote("Status {draft}"), '"Status {draft}"')

    def test_empty_string_gets_quoted(self):
        self.assertEqual(yaml_quote(""), '""')

    def test_leading_space_gets_quoted(self):
        self.assertEqual(yaml_quote(" leading"), '" leading"')

    def test_trailing_space_gets_quoted(self):
        self.assertEqual(yaml_quote("trailing "), '"trailing "')

    def test_embedded_double_quote_escaped(self):
        result = yaml_quote('say "hello"')
        self.assertEqual(result, '"say \\"hello\\""')

    def test_backslash_escaped_when_quoting_triggered(self):
        # Backslash escaping applies when quoting is triggered by another special char
        result = yaml_quote("path\\to: here")
        self.assertEqual(result, '"path\\\\to: here"')


class TestYamlList(unittest.TestCase):
    def test_simple_list(self):
        result = yaml_list(["Todo", "Done"])
        self.assertEqual(result, "    - Todo\n    - Done")

    def test_special_chars_quoted(self):
        result = yaml_list(["Todo", "In Progress: Active"])
        self.assertIn('"In Progress: Active"', result)


class TestWorkflowYamlGeneration(unittest.TestCase):
    """Integration tests: generated YAML must parse and preserve values."""

    def test_state_names_with_colon(self):
        yaml_str = build_workflow_yaml(
            active_states=["Todo", "In Progress: Active"],
            terminal_states=["Done", "Closed: Final"],
            ws_root="/tmp/ws",
            shim_path="/tmp/shim.py",
        )
        data = parse_first_doc(yaml_str)
        self.assertEqual(data["tracker"]["active_states"], ["Todo", "In Progress: Active"])
        self.assertEqual(data["tracker"]["terminal_states"], ["Done", "Closed: Final"])

    def test_state_names_with_hash(self):
        yaml_str = build_workflow_yaml(
            active_states=["Review #2"],
            terminal_states=["Done"],
            ws_root="/tmp/ws",
            shim_path="/tmp/shim.py",
        )
        data = parse_first_doc(yaml_str)
        self.assertEqual(data["tracker"]["active_states"], ["Review #2"])

    def test_state_names_with_braces(self):
        yaml_str = build_workflow_yaml(
            active_states=["Status {draft}"],
            terminal_states=["Done"],
            ws_root="/tmp/ws",
            shim_path="/tmp/shim.py",
        )
        data = parse_first_doc(yaml_str)
        self.assertEqual(data["tracker"]["active_states"], ["Status {draft}"])

    def test_path_with_spaces(self):
        yaml_str = build_workflow_yaml(
            active_states=["Todo"],
            terminal_states=["Done"],
            ws_root="/home/user/my workspaces/project",
            shim_path="/path/to my scripts/shim.py",
        )
        data = parse_first_doc(yaml_str)
        self.assertEqual(data["workspace"]["root"], "/home/user/my workspaces/project")
        self.assertEqual(data["agent_server"]["command"], "python3 /path/to my scripts/shim.py")

    def test_all_values_are_strings(self):
        yaml_str = build_workflow_yaml(
            active_states=["Todo", "In Progress: Active", "Review #2", "Status {draft}"],
            terminal_states=["Done", "Closed: Final"],
            ws_root="/home/user/my workspaces/project",
            shim_path="/path/to scripts/shim.py",
        )
        data = parse_first_doc(yaml_str)
        for s in data["tracker"]["active_states"]:
            self.assertIsInstance(s, str, f"Expected string, got {type(s)}: {s}")
        for s in data["tracker"]["terminal_states"]:
            self.assertIsInstance(s, str, f"Expected string, got {type(s)}: {s}")
        self.assertIsInstance(data["workspace"]["root"], str)
        self.assertIsInstance(data["agent_server"]["command"], str)

    def test_valid_yaml_roundtrip(self):
        yaml_str = build_workflow_yaml(
            active_states=["Todo", "In Progress: Active"],
            terminal_states=["Done"],
            ws_root="/tmp/ws",
            shim_path="/tmp/shim.py",
        )
        # Must not raise
        data = parse_first_doc(yaml_str)
        self.assertIsNotNone(data)

    def test_slug_with_special_chars(self):
        yaml_str = build_workflow_yaml(
            active_states=["Todo"],
            terminal_states=["Done"],
            ws_root="/tmp/ws",
            shim_path="/tmp/shim.py",
            slug="project: alpha #1",
        )
        data = parse_first_doc(yaml_str)
        self.assertEqual(data["tracker"]["project_slug"], "project: alpha #1")


if __name__ == "__main__":
    unittest.main()
