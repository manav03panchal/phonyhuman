# Security

## Threat model

phonyhuman dispatches Claude Code agents to work on Linear issues
autonomously.  Because agents run unattended, the shim passes
`--dangerously-skip-permissions` to skip interactive permission prompts.
This creates a **prompt-injection attack surface**: a malicious Linear issue
description (or comment) could trick the agent into executing arbitrary
shell commands on the host.

### Attack vector

```
Attacker writes malicious issue → Symphony polls Linear → prompt sent to
Claude Code with --dangerously-skip-permissions → agent executes injected
commands without user confirmation
```

### Mitigations

#### Tool allowlist (primary)

`claude-shim.py` passes `--allowedTools` alongside
`--dangerously-skip-permissions` to restrict the agent to a curated set of
tools.  Bash access is scoped to specific command prefixes (e.g.
`Bash(git:*)`, `Bash(make:*)`), so even if a prompt injection succeeds the
agent cannot invoke arbitrary shell commands.

The default allowlist covers common orchestration commands:

| Tool | Scope |
|---|---|
| `Read`, `Write`, `Edit`, `Glob`, `Grep` | File operations (workspace only) |
| `Agent` | Sub-agent spawning |
| `Bash(git:*)` | Git operations |
| `Bash(gh:*)` | GitHub CLI |
| `Bash(python3:*)` | Python (for linear-cli, tests) |
| `Bash(make:*)`, `Bash(mix:*)`, `Bash(npm:*)`, `Bash(npx:*)`, `Bash(cargo:*)` | Build tools |
| `Bash(ls:*)`, `Bash(cat:*)`, `Bash(mkdir:*)`, etc. | Common file utilities |

Override with `CLAUDE_ALLOWED_TOOLS` (space-separated).  Set to `none` to
disable the allowlist entirely (not recommended).

#### Workspace isolation

Each agent runs in an isolated workspace directory created per-issue.
File operations are scoped to that workspace.

#### Linear API key scope

The Linear API key used by agents has read/write access only to the
configured project.  Agents cannot access other projects or admin settings.

### Residual risks

- **Scoped Bash escapes**: The `Bash(git:*)` pattern trusts `git` as a
  command prefix.  A sophisticated injection could abuse `git` subcommands
  (e.g. `git config --global`) to modify global state.  Operators should run
  agents in containers or VMs for defense-in-depth.
- **File-system escapes**: `Read`/`Write`/`Edit` tools may access files
  outside the workspace via absolute or `../` paths.  Container isolation
  mitigates this.
- **Network access**: Agents can make outbound network requests via allowed
  tools.  Network policies or firewall rules are recommended in production.
- **Token exfiltration**: An injection could read environment variables
  (LINEAR_API_KEY, GITHUB_TOKEN) via allowed tools and exfiltrate them.
  Use short-lived tokens and rotate them regularly.

### Recommendations for production

1. Run agents in ephemeral containers with no persistent state.
2. Use read-only filesystem mounts except for the workspace directory.
3. Apply network egress policies to restrict outbound connections.
4. Use short-lived, narrowly-scoped API tokens.
5. Monitor agent output for unexpected tool invocations.
6. Customize `CLAUDE_ALLOWED_TOOLS` to the minimum set needed for your
   project.
