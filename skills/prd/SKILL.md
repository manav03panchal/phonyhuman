---
name: prd
description: |
  Decompose a Product Requirements Document (PRD) into Linear issues
  structured for phonyhuman agent execution. Handles issue creation,
  dependency ordering, sizing, and proper description formatting so
  agents can pick up and implement the work autonomously.
---

# PRD to Linear Issues

Use this skill to take a PRD and create a set of Linear issues that
phonyhuman agents can execute autonomously. The output is a fully
dependency-ordered backlog of well-structured issues ready for sprint
planning.

## Goal

Read a PRD, decompose it into agent-sized Linear issues with proper
descriptions, acceptance criteria, validation steps, and dependency
chains, then create them all in Linear in **Backlog** state.

## Inputs

- **PRD source**: one of:
  - A file path (markdown, PDF, text)
  - A URL (fetch and parse)
  - Pasted text in the conversation
- **Linear project**: the project slug or name where issues should be created
- **Target repo**: the repository the agents will work in (for file path references)
- **Tech stack hints** (optional): language, framework, test runner, build commands
  to include in validation sections

If project or repo aren't provided, ask before proceeding. Tech stack
can be inferred from the repo if accessible.

## Prerequisites

You need access to Linear via one of these (in order of preference):

1. **`linear_graphql` tool** — available in Symphony app-server sessions
2. **Linear MCP server** — configured in Claude Code settings
3. **`linear-cli.py graphql`** — ships with phonyhuman, reads the API
   key from the TOML config automatically (no need to handle the key)

For option 3, call via bash:

```bash
python3 ~/.phonyhuman/bin/linear-cli.py graphql '<query>' '{"var": "value"}'
```

The CLI finds the API key from any `*.toml` phonyhuman config in the
current directory. Do NOT read or echo the API key yourself.

All GraphQL examples in this skill are written as query/variable pairs.
When using `linear-cli.py`, pass the query as the first argument and
variables JSON as the second.

## Step 0: Gather context and set up Linear

1. Read the PRD fully. Do not skim.
2. If a target repo is accessible, scan its structure to understand:
   - Language and framework (for validation commands)
   - Existing patterns and conventions (for "follow the pattern in..." references)
   - Test infrastructure (test runner, test directory structure)
   - Build commands (for validation sections)

### Find or create the Linear project

3. Look up the team first — you'll need the team ID for everything:

```graphql
query TeamAndStates {
  teams(first: 10) {
    nodes {
      id
      key
      name
      states {
        nodes {
          id
          name
          type
        }
      }
    }
  }
}
```

4. Try to find the project by slug or name:

```graphql
query ProjectBySlug($slug: String!) {
  projects(filter: { slugId: { eq: $slug } }, first: 1) {
    nodes {
      id
      name
      slugId
    }
  }
}
```

If the project doesn't exist, create it:

```graphql
mutation CreateProject($input: ProjectCreateInput!) {
  projectCreate(input: $input) {
    success
    project {
      id
      name
      slugId
      url
    }
  }
}
```

Variables:

```json
{
  "input": {
    "name": "My Project",
    "teamIds": ["<team-id>"]
  }
}
```

Use introspection if `ProjectCreateInput` shape is unfamiliar:

```graphql
query ProjectCreateInputShape {
  __type(name: "ProjectCreateInput") {
    inputFields {
      name
      type {
        kind
        name
        ofType { kind name }
      }
    }
  }
}
```

### Verify workflow states

5. Check the team's workflow states against the required phonyhuman states:

| State | Type | Required |
|-------|------|----------|
| **Backlog** | backlog | Yes |
| **Todo** | unstarted | Yes |
| **In Progress** | started | Yes |
| **Human Review** | started | Yes — exact name required |
| **Merging** | started | Yes — exact name required |
| **Rework** | started | Yes — exact name required |
| **Done** | completed | Yes |

Compare the team's existing states from step 3 against this list. If any
are missing, create them:

```graphql
mutation CreateWorkflowState($input: WorkflowStateCreateInput!) {
  workflowStateCreate(input: $input) {
    success
    workflowState {
      id
      name
      type
    }
  }
}
```

Variables (example for "Human Review"):

```json
{
  "input": {
    "name": "Human Review",
    "type": "started",
    "teamId": "<team-id>"
  }
}
```

Use introspection if the input shape is unfamiliar:

```graphql
query WorkflowStateCreateInputShape {
  __type(name: "WorkflowStateCreateInput") {
    inputFields {
      name
      type {
        kind
        name
        ofType { kind name }
      }
    }
  }
}
```

**Critical:** "Human Review", "Merging", and "Rework" must be named
exactly as shown — phonyhuman uses exact string matching. Standard states
like "Backlog", "Todo", "In Progress", and "Done" usually exist by
default, but verify. Only create states that are missing.

After setup, record:
- `team_id` — for issue creation
- `project_id` — for issue creation
- `backlog_state_id` — all issues go into Backlog

6. If you need to discover the `issueCreate` input shape:

```graphql
query IssueCreateInputShape {
  __type(name: "IssueCreateInput") {
    inputFields {
      name
      type {
        kind
        name
        ofType {
          kind
          name
        }
      }
    }
  }
}
```

## Step 1: Analyze and decompose the PRD

Break the PRD into discrete, agent-executable issues. Follow these
decomposition principles:

### Sizing rules

Each issue should be:
- **1-5 files modified** — agent can hold full context
- **Single responsibility** — one feature, one bug fix, one refactor
- **Verifiable in isolation** — tests can run without other pending work
- **Completable in 10-15 agent turns** (~30-60 minutes wall clock)

If a piece of work touches more than 5 files or has multiple independent
concerns, split it further.

### Decomposition strategy

1. **Infrastructure first**: Shared foundations (models, API clients, base
   components, config) become the earliest issues with nothing blocking them.

2. **Vertical slices**: Each subsequent issue delivers a thin, end-to-end
   slice of functionality rather than horizontal layers.
   - Bad: "Backend for feature X" + "Frontend for feature X"
   - Good: "Add create user flow (API + form + tests)" + "Add edit user
     flow (API + form + tests)"

3. **One concern per issue**: Never mix refactoring with feature work.

4. **Maximize parallelism**: Issues that touch different parts of the
   codebase should be independent (no `blockedBy`). Only add dependencies
   when there's a true technical need:
   - Issue B builds on an API/model/component that Issue A creates
   - Issue B's tests would fail without Issue A's code
   - Issues modify the same files and would cause merge conflicts

5. **Order by dependency depth**: Identify the critical path. Issues with
   no dependencies come first. Issues at the end of the longest chain
   are the critical path — flag these.

### Output of this step

Produce a decomposition plan as a numbered list before creating anything:

```
Issue 1: [title] (no dependencies)
  - scope: [brief description]
  - files: [expected files]
  - estimate: [1-3 points]

Issue 2: [title] (blockedBy: 1)
  - scope: [brief description]
  - files: [expected files]
  - estimate: [1-3 points]

Issue 3: [title] (no dependencies, parallel with 1-2)
  - scope: [brief description]
  - files: [expected files]
  - estimate: [1-3 points]

...
```

Present this plan for review before creating issues. If running
unattended, proceed directly to creation.

## Step 2: Write issue descriptions

Each issue description must follow this structure. The agent's only input
is the issue description — if it's not in the issue, the agent doesn't
know about it.

```markdown
## Summary

One or two sentences: what is being built/fixed and why.

## Current Behavior

What exists today. For new features on a new codebase: "N/A — new feature"
or describe the current state of the relevant area.

## Desired Behavior

What should exist after this issue is implemented. Be specific and testable.

## Requirements

- [ ] Requirement 1 — specific, independently verifiable
- [ ] Requirement 2 — include edge cases that matter
- [ ] Requirement 3 — include error handling expectations

## Files / Areas of Interest

- `src/path/to/file.ts` — what to do here
- `src/path/to/other.ts` — why this file is relevant
- `tests/path/to/test.ts` — existing tests to update

## Out of Scope

- Do NOT modify [area]
- Do NOT change [feature]
- [Other boundaries]

## Acceptance Criteria

- [ ] [Testable criterion with action verb: "displays", "returns", "prevents"]
- [ ] [Include negative cases: "does NOT allow empty submissions"]
- [ ] [Reference specific UI elements or API responses]

## Validation

- [ ] `[test command]` passes
- [ ] `[build command]` succeeds
- [ ] `[lint command]` passes
- [ ] [Any manual verification the agent can perform]

## Test Plan

- [ ] Add unit test for [component/function]
- [ ] Add integration test for [flow/endpoint]
- [ ] Existing tests pass without modification
```

### Description quality rules

- **Be specific about outcomes, not implementation** — say what should
  happen, not how to code it (unless the how matters).
- **Include file paths** when you know or can infer them from the repo.
- **Reference existing patterns** — "Follow the same pattern as
  `src/api/users.ts`" gives the agent a concrete template.
- **State current vs desired behavior** — always.
- **Include example inputs/outputs** for data processing features.
- **List what NOT to change** — prevents scope creep.
- **Validation is sacred** — the agent treats `Validation` items as
  non-negotiable gates. Include the right build/test/lint commands for
  the project's tech stack.

### Validation commands by tech stack

Use the appropriate commands for the project:

| Stack | Validation |
|-------|-----------|
| Node/React/Vite | `npm test`, `npm run build`, `npm run lint` |
| Rust/Tauri | `cargo test`, `cargo build --release`, `cargo clippy -- -D warnings` |
| Python | `pytest`, `mypy .`, `ruff check .` |
| Go | `go test ./...`, `go build ./...`, `golangci-lint run` |
| Elixir | `mix test`, `mix compile --warnings-as-errors`, `mix credo` |

## Step 3: Create issues in Linear

Create each issue using the `issueCreate` mutation. All issues go into
**Backlog** state so a human can review before moving to Todo.

### Create a single issue

```graphql
mutation CreateIssue($input: IssueCreateInput!) {
  issueCreate(input: $input) {
    success
    issue {
      id
      identifier
      title
      url
    }
  }
}
```

Variables:

```json
{
  "input": {
    "title": "Add user registration API endpoint",
    "description": "## Summary\n\nAdd POST /api/auth/register endpoint...",
    "teamId": "<team-id>",
    "projectId": "<project-id>",
    "stateId": "<backlog-state-id>",
    "priority": 2
  }
}
```

Priority values: `0` = No priority, `1` = Urgent, `2` = High, `3` = Medium, `4` = Low.

### Set up dependencies

After creating all issues, add `blockedBy` relations using the issue IDs
returned from creation:

```graphql
mutation CreateRelation($input: IssueRelationCreateInput!) {
  issueRelationCreate(input: $input) {
    success
    issueRelation {
      id
      type
    }
  }
}
```

Variables:

```json
{
  "input": {
    "issueId": "<blocked-issue-id>",
    "relatedIssueId": "<blocking-issue-id>",
    "type": "blocks"
  }
}
```

This means `relatedIssueId` blocks `issueId` — i.e., the blocking issue
must complete before the blocked issue can be picked up.

### Add estimates (optional)

If you included point estimates in the decomposition, set them:

```graphql
mutation SetEstimate($id: String!, $estimate: Float!) {
  issueUpdate(id: $id, input: { estimate: $estimate }) {
    success
    issue {
      id
      estimate
    }
  }
}
```

## Step 4: Verify and summarize

After all issues are created:

1. **Verify the dependency graph is acyclic** — no circular blockedBy chains.
2. **Verify all issues are in Backlog** — none should be in Todo yet.
3. **Verify all issues are in the correct project**.
4. **Identify parallel tracks** — which issues can run simultaneously.
5. **Identify the critical path** — the longest dependency chain.

Present a summary:

```
Created N issues in project [name]:

Track 1 (critical path):
  [PROJ-1] Issue title (no deps)
  [PROJ-3] Issue title (blocked by PROJ-1)
  [PROJ-6] Issue title (blocked by PROJ-3)

Track 2 (parallel):
  [PROJ-2] Issue title (no deps)
  [PROJ-5] Issue title (blocked by PROJ-2)

Track 3 (parallel):
  [PROJ-4] Issue title (no deps)

Estimated total: X points
Critical path: Y points
Max parallelism: Z issues at once

Next step: review the issues in Linear, then move them from Backlog
to Todo to start agent execution.
```

## Introspection fallback

If `issueCreate` or `issueRelationCreate` mutations fail or have
unexpected input shapes, use introspection to discover the correct schema:

```graphql
query DiscoverMutation($name: String!) {
  __type(name: $name) {
    inputFields {
      name
      type {
        kind
        name
        ofType { kind name ofType { kind name } }
      }
    }
  }
}
```

Use with `"name": "IssueCreateInput"` or `"name": "IssueRelationCreateInput"`.

## Usage rules

- **Always create issues in Backlog** — never Todo. Moving to Todo is a
  human decision during sprint planning.
- **Always present the decomposition plan before creating issues** when
  running interactively. Skip the review step only in unattended mode.
- **Do not create issues with vague descriptions** — every issue must have
  Summary, Requirements, Acceptance Criteria, and Validation sections at
  minimum.
- **Do not create issues that are too large** — if an issue touches more
  than 5 files or has multiple independent concerns, split it.
- **Do not create circular dependencies** — the dependency graph must be
  a DAG.
- **Prefer fewer dependencies over more** — only add `blockedBy` when
  there's a true technical need. Independent issues run in parallel.
- **Include file paths from the actual repo** when the repo is accessible.
  Don't guess paths — scan the repo structure first.
- **Match the project's existing conventions** — if the repo uses a
  specific test framework, component structure, or naming pattern,
  reference those in issue descriptions.
- **Use the `linear` skill** (`skills/linear/SKILL.md`) for GraphQL
  patterns and troubleshooting.
