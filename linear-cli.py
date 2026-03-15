#!/usr/bin/env python3
"""
linear-cli — Minimal Linear CLI for Claude Code agents.

Gives Claude the ability to interact with Linear issues from the workspace.
Requires LINEAR_API_KEY in the environment.

Usage:
  linear-cli comment <issue-id> <body>       Post a comment
  linear-cli edit-comment <comment-id> <body> Edit an existing comment
  linear-cli get-issue <issue-id>             Get issue details
  linear-cli get-comments <issue-id>          Get issue comments
  linear-cli set-state <issue-id> <state>     Move issue to a state (e.g. "Done")
  linear-cli attach-url <issue-id> <url> [title]  Attach a URL to an issue
  linear-cli graphql <query> [variables-json] Raw GraphQL
"""

import json
import os
import re
import sys
import urllib.parse
import urllib.request
import urllib.error


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


_DEFAULT_ENDPOINT = "https://api.linear.app/graphql"


def _validate_endpoint(url):
    """Validate that the endpoint is HTTPS on the linear.app domain."""
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https":
        die(f"LINEAR_ENDPOINT must use HTTPS (got {parsed.scheme!r})")
    host = parsed.hostname or ""
    if host != "linear.app" and not host.endswith(".linear.app"):
        die(
            f"LINEAR_ENDPOINT must be on the linear.app domain (got {host!r})"
        )
    return url


ENDPOINT = _validate_endpoint(
    os.environ.get("LINEAR_ENDPOINT", _DEFAULT_ENDPOINT)
)


def _find_api_key():
    """Resolve LINEAR_API_KEY from env or a phonyhuman TOML config."""
    key = os.environ.get("LINEAR_API_KEY", "")
    if key:
        return key
    # Search well-known phonyhuman config files in the current directory
    import tomllib
    for candidate in ("symphony.toml", "phonyhuman.toml"):
        try:
            with open(candidate, "rb") as f:
                cfg = tomllib.load(f)
            key = cfg.get("linear", {}).get("api_key", "")
            if key:
                return key
        except FileNotFoundError:
            continue
        except Exception:
            continue
    return ""


API_KEY = _find_api_key()


_TEAM_KEY_RE = re.compile(r"^[A-Z][A-Z0-9]*$")


def parse_identifier(identifier):
    """Parse 'HUM-5' into ('HUM', 5). Returns None if it's a UUID.

    Validates team_key matches [A-Z][A-Z0-9]* (uppercase letters/digits,
    starting with a letter).
    """
    if "-" in identifier:
        parts = identifier.rsplit("-", 1)
        if len(parts) == 2 and parts[1].isdigit():
            team_key = parts[0]
            if not _TEAM_KEY_RE.match(team_key):
                die(
                    f"Invalid team key '{team_key}' in identifier '{identifier}'. "
                    "Team keys must be uppercase letters and digits (e.g. 'HUM', 'ENG2')."
                )
            return team_key, int(parts[1])
    return None


def resolve_issue_id(identifier):
    """Resolve a human identifier (HUM-5) or UUID to issue UUID."""
    parsed = parse_identifier(identifier)
    if parsed:
        team_key, number = parsed
        # Step 1: find the team
        result = graphql(
            """query($teamKey: String!) {
                teams(filter: { key: { eq: $teamKey } }) {
                    nodes { id }
                }
            }""",
            {"teamKey": team_key},
        )
        teams = result.get("data", {}).get("teams", {}).get("nodes", [])
        if not teams:
            die(f"Team '{team_key}' not found")
        team_id = teams[0]["id"]

        # Step 2: find the issue by number within that team
        result = graphql(
            """query($number: Float!) {
                issues(filter: { number: { eq: $number } }, first: 1) {
                    nodes { id identifier }
                }
            }""",
            {"number": number},
        )
        nodes = result.get("data", {}).get("issues", {}).get("nodes", [])
        if not nodes:
            die(f"Issue {identifier} not found")
        return nodes[0]["id"]
    else:
        return identifier


def graphql(query, variables=None):
    if not API_KEY:
        die("LINEAR_API_KEY not set")

    body = json.dumps({"query": query, "variables": variables or {}}).encode()
    req = urllib.request.Request(
        ENDPOINT,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": API_KEY,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode())
            # Surface GraphQL-level errors
            gql_errors = data.get("errors")
            if gql_errors:
                messages = "; ".join(
                    e.get("message", str(e)) for e in gql_errors
                )
                extensions = gql_errors[0].get("extensions", {})
                error_code = extensions.get("code", "")
                if error_code == "AUTHENTICATION_ERROR":
                    die(
                        f"Authentication failed: {messages}. "
                        "Check that LINEAR_API_KEY is valid."
                    )
                if error_code == "RATELIMITED":
                    die(f"Rate limited (GraphQL): {messages}")
                die(f"GraphQL error: {messages}")
            return data
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:500]
        if e.code == 401:
            die(
                "Authentication failed (HTTP 401). "
                "Check that LINEAR_API_KEY is set and valid."
            )
        if e.code == 429:
            retry_after = e.headers.get("Retry-After", "")
            msg = "Rate limited (HTTP 429)."
            if retry_after:
                msg += f" Retry after {retry_after} seconds."
            if body:
                msg += f" Response: {body}"
            die(msg)
        die(f"HTTP {e.code}: {body}")
    except urllib.error.URLError as e:
        die(f"Network error: {e.reason}")
    except TimeoutError:
        die("Request timed out after 30 seconds.")


def cmd_comment(issue_id, body):
    real_id = resolve_issue_id(issue_id)
    result = graphql(
        """mutation($issueId: String!, $body: String!) {
            commentCreate(input: { issueId: $issueId, body: $body }) {
                success
                comment { id body }
            }
        }""",
        {"issueId": real_id, "body": body},
    )
    comment = result.get("data", {}).get("commentCreate", {})
    if comment.get("success"):
        cid = comment.get("comment", {}).get("id", "")
        print(f"Comment posted: {cid}")
    else:
        print(json.dumps(result, indent=2))


def cmd_edit_comment(comment_id, body):
    result = graphql(
        """mutation($id: String!, $body: String!) {
            commentUpdate(id: $id, input: { body: $body }) {
                success
                comment { id }
            }
        }""",
        {"id": comment_id, "body": body},
    )
    update = result.get("data", {}).get("commentUpdate", {})
    if update.get("success"):
        print(f"Comment updated: {comment_id}")
    else:
        print(json.dumps(result, indent=2))


def cmd_get_issue(issue_id):
    real_id = resolve_issue_id(issue_id)
    result = graphql(
        """query($id: String!) {
            issue(id: $id) {
                id identifier title description
                state { name }
                priority url
                labels { nodes { name } }
                assignee { name }
                comments { nodes { id body createdAt user { name } } }
                attachments { nodes { url title } }
            }
        }""",
        {"id": real_id},
    )
    issue = result.get("data", {}).get("issue")
    if issue:
        print(json.dumps(issue, indent=2))
    else:
        die(f"Issue not found: {issue_id}")


def cmd_get_comments(issue_id):
    real_id = resolve_issue_id(issue_id)
    result = graphql(
        """query($id: String!) {
            issue(id: $id) {
                id identifier
                comments(first: 50) {
                    nodes { id body createdAt updatedAt user { name } }
                }
            }
        }""",
        {"id": real_id},
    )
    issue = result.get("data", {}).get("issue")
    if issue:
        comments = issue.get("comments", {}).get("nodes", [])
        print(json.dumps(comments, indent=2))
    else:
        die(f"Issue not found: {issue_id}")


def cmd_set_state(issue_id, state_name):
    real_issue_id = resolve_issue_id(issue_id)
    # Get the issue's team states
    issue_result = graphql(
        """query($id: String!) {
            issue(id: $id) { id team { id states { nodes { id name } } } }
        }""",
        {"id": real_issue_id},
    )
    issue = issue_result.get("data", {}).get("issue")
    if not issue:
        die(f"Issue not found: {issue_id}")
    states = issue.get("team", {}).get("states", {}).get("nodes", [])

    state_id = None
    for s in states:
        if s["name"].lower() == state_name.lower():
            state_id = s["id"]
            break

    if not state_id:
        available = ", ".join(s["name"] for s in states)
        die(f"State '{state_name}' not found. Available: {available}")

    result = graphql(
        """mutation($id: String!, $stateId: String!) {
            issueUpdate(id: $id, input: { stateId: $stateId }) {
                success
                issue { identifier state { name } }
            }
        }""",
        {"id": real_issue_id, "stateId": state_id},
    )
    update = result.get("data", {}).get("issueUpdate", {})
    if update.get("success"):
        new_state = update.get("issue", {}).get("state", {}).get("name", "")
        ident = update.get("issue", {}).get("identifier", "")
        print(f"{ident} → {new_state}")
    else:
        print(json.dumps(result, indent=2))


def cmd_attach_url(issue_id, url, title=None):
    real_id = resolve_issue_id(issue_id)
    inp = {"issueId": real_id, "url": url}
    if title:
        inp["title"] = title

    result = graphql(
        """mutation($input: AttachmentCreateInput!) {
            attachmentCreate(input: $input) {
                success
                attachment { id url title }
            }
        }""",
        {"input": inp},
    )
    attach = result.get("data", {}).get("attachmentCreate", {})
    if attach.get("success"):
        print(f"Attached: {url}")
    else:
        print(json.dumps(result, indent=2))


def cmd_graphql(query, variables_json=None):
    variables = {}
    if variables_json:
        variables = json.loads(variables_json)
    result = graphql(query, variables)
    print(json.dumps(result, indent=2))


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip())
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "comment" and len(sys.argv) >= 4:
        cmd_comment(sys.argv[2], sys.argv[3])
    elif cmd == "edit-comment" and len(sys.argv) >= 4:
        cmd_edit_comment(sys.argv[2], sys.argv[3])
    elif cmd == "get-issue" and len(sys.argv) >= 3:
        cmd_get_issue(sys.argv[2])
    elif cmd == "get-comments" and len(sys.argv) >= 3:
        cmd_get_comments(sys.argv[2])
    elif cmd == "set-state" and len(sys.argv) >= 4:
        cmd_set_state(sys.argv[2], sys.argv[3])
    elif cmd == "attach-url" and len(sys.argv) >= 4:
        title = sys.argv[4] if len(sys.argv) >= 5 else None
        cmd_attach_url(sys.argv[2], sys.argv[3], title)
    elif cmd == "graphql" and len(sys.argv) >= 3:
        variables = sys.argv[3] if len(sys.argv) >= 4 else None
        cmd_graphql(sys.argv[2], variables)
    else:
        print(__doc__.strip())
        sys.exit(1)


if __name__ == "__main__":
    main()
