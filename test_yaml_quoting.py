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


def yaml_block_scalar(value, indent=4):
    """Format a multiline string as a YAML literal block scalar body.

    All lines are re-indented to the given level, preserving relative
    indentation.  This prevents YAML injection through unindented lines
    or document markers (e.g. ``---``).
    """
    prefix = " " * indent
    lines = str(value).splitlines()
    if not lines:
        return prefix
    min_indent = None
    for line in lines:
        stripped = line.lstrip()
        if stripped:
            leading = len(line) - len(stripped)
            if min_indent is None or leading < min_indent:
                min_indent = leading
    if min_indent is None:
        min_indent = 0
    result = []
    for line in lines:
        stripped = line.lstrip()
        if stripped:
            relative = len(line) - len(stripped) - min_indent
            result.append(prefix + " " * relative + stripped)
        else:
            result.append("")
    return "\n".join(result)


def build_hooks_yaml(after_create, before_run="", after_run="", before_remove=""):
    """Reproduce hooks_section generation from bin/phonyhuman."""
    hooks_section = f"  after_create: |\n{yaml_block_scalar(after_create)}\n"
    if before_run:
        hooks_section += f"  before_run: |\n{yaml_block_scalar(before_run)}\n"
    if after_run:
        hooks_section += f"  after_run: |\n{yaml_block_scalar(after_run)}\n"
    if before_remove:
        hooks_section += f"  before_remove: |\n{yaml_block_scalar(before_remove)}\n"
    return f"---\ntracker:\n  kind: linear\nhooks:\n{hooks_section}agent:\n  max_concurrent_agents: 5\n---\n"


class TestYamlBlockScalar(unittest.TestCase):
    """Tests for yaml_block_scalar preventing YAML injection."""

    def test_simple_single_line(self):
        result = yaml_block_scalar("echo hello")
        self.assertEqual(result, "    echo hello")

    def test_multiline_uniform_indent(self):
        result = yaml_block_scalar("line1\nline2\nline3")
        self.assertEqual(result, "    line1\n    line2\n    line3")

    def test_preserves_relative_indent(self):
        result = yaml_block_scalar("if true\n  echo yes\nfi")
        self.assertEqual(result, "    if true\n      echo yes\n    fi")

    def test_strips_existing_artificial_indent(self):
        # Values with pre-existing indent should be normalized
        result = yaml_block_scalar("    line1\n    line2")
        self.assertEqual(result, "    line1\n    line2")

    def test_empty_value(self):
        result = yaml_block_scalar("")
        self.assertEqual(result, "    ")

    def test_empty_lines_preserved(self):
        result = yaml_block_scalar("line1\n\nline3")
        self.assertEqual(result, "    line1\n\n    line3")


class TestHooksYamlInjection(unittest.TestCase):
    """Tests that hook values cannot inject YAML structure."""

    def test_document_separator_in_hook_does_not_split(self):
        """A --- in a hook value must not create a new YAML document."""
        yaml_str = build_hooks_yaml("echo hello\n---\ntracker:\n  kind: evil")
        docs = list(yaml.safe_load_all(yaml_str))
        # Should be exactly 2 docs: the config dict and the trailing None
        non_none = [d for d in docs if d is not None]
        self.assertEqual(len(non_none), 1, f"Expected 1 non-None doc, got {len(non_none)}: {docs}")
        self.assertEqual(non_none[0]["tracker"]["kind"], "linear")

    def test_colon_in_hook_value(self):
        """A colon in hook value must not create new YAML keys."""
        yaml_str = build_hooks_yaml("echo 'key: value'")
        data = parse_first_doc(yaml_str)
        self.assertIn("echo", data["hooks"]["after_create"])

    def test_multiline_hook_with_yaml_special_chars(self):
        """Hook with multiple YAML-special chars stays within literal block."""
        hook = "echo '---'\necho 'key: value'\necho '# comment'\necho '[list]'"
        yaml_str = build_hooks_yaml(hook)
        data = parse_first_doc(yaml_str)
        self.assertIn("---", data["hooks"]["after_create"])
        self.assertIn("key: value", data["hooks"]["after_create"])

    def test_before_run_injection(self):
        yaml_str = build_hooks_yaml("echo ok", before_run="echo hi\n---\nevil: true")
        docs = list(yaml.safe_load_all(yaml_str))
        non_none = [d for d in docs if d is not None]
        self.assertEqual(len(non_none), 1)

    def test_after_run_injection(self):
        yaml_str = build_hooks_yaml("echo ok", after_run="echo hi\n---\nevil: true")
        docs = list(yaml.safe_load_all(yaml_str))
        non_none = [d for d in docs if d is not None]
        self.assertEqual(len(non_none), 1)

    def test_worktree_default_values_valid(self):
        """Default worktree hook values produce valid YAML."""
        after_create = (
            "export LOCAL_REPO='/tmp/repo'\n"
            "BRANCH=\"symphony/$(basename \"$PWD\")\"\n"
            "git -C \"$LOCAL_REPO\" fetch origin main\n"
            "git -C \"$LOCAL_REPO\" worktree add \"$PWD\" -b \"$BRANCH\" origin/main"
        )
        before_remove = (
            "export LOCAL_REPO='/tmp/repo'\n"
            "git -C \"$LOCAL_REPO\" worktree remove \"$PWD\" --force 2>/dev/null || true"
        )
        yaml_str = build_hooks_yaml(after_create, before_remove=before_remove)
        data = parse_first_doc(yaml_str)
        self.assertIn("export LOCAL_REPO", data["hooks"]["after_create"])
        self.assertIn("worktree remove", data["hooks"]["before_remove"])

    def test_clone_default_value_valid(self):
        """Default clone hook value produces valid YAML."""
        yaml_str = build_hooks_yaml('git clone --depth 1 "$SOURCE_REPO_URL" .')
        data = parse_first_doc(yaml_str)
        self.assertIn("git clone", data["hooks"]["after_create"])


if __name__ == "__main__":
    unittest.main()
