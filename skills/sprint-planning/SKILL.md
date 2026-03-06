---
name: sprint-planning
description: |
  Guide for Scrum Masters using Claude Code to set up Linear issues that
  phonyhuman agents can pick up and execute autonomously. Covers issue
  structure, Linear states, dependencies, acceptance criteria, and
  common pitfalls. Use during Sprint Planning sessions.
---

# Sprint Planning for phonyhuman

This skill teaches you how to create and organize Linear issues so that
phonyhuman — an autonomous agent orchestrator — can pick them up, implement
them, open pull requests, and land code without human intervention (except
for PR review).

**You do not need to read the phonyhuman codebase to use this skill.** This
document is self-contained and covers everything a Scrum Master or tech lead
needs to know to run Sprint Planning for an agent-driven workflow.

---

## Table of Contents

1. [How phonyhuman works (the 30-second version)](#how-phonyhuman-works)
2. [Linear workspace setup (one-time)](#linear-workspace-setup)
3. [Issue lifecycle and states](#issue-lifecycle-and-states)
4. [Writing issues agents can execute](#writing-issues-agents-can-execute)
5. [Acceptance criteria that actually gate quality](#acceptance-criteria)
6. [Validation and test plans](#validation-and-test-plans)
7. [Dependencies and ordering](#dependencies-and-ordering)
8. [Sizing and scoping for agents](#sizing-and-scoping-for-agents)
9. [Labels and metadata](#labels-and-metadata)
10. [Multi-issue features and epics](#multi-issue-features-and-epics)
11. [The human review loop](#the-human-review-loop)
12. [Rework and feedback](#rework-and-feedback)
13. [Common pitfalls](#common-pitfalls)
14. [Issue templates](#issue-templates)
15. [Sprint Planning checklist](#sprint-planning-checklist)

---

## How phonyhuman works

phonyhuman is an orchestrator that:

1. **Polls** your Linear project every few seconds for issues in active states.
2. **Creates an isolated workspace** (git worktree or clone) for each issue.
3. **Dispatches a Claude Code agent** to implement the issue autonomously.
4. The agent **reads the issue description**, plans in a workpad comment,
   writes code, commits, pushes a branch, opens a PR, and attaches it to the
   Linear issue.
5. The agent **moves the issue to Human Review** when it believes all
   acceptance criteria are met and PR checks are green.
6. A human reviews the PR. If approved, they move the issue to **Merging**.
7. The agent picks it back up, monitors CI, and **squash-merges the PR**.
8. The issue moves to **Done**.

**Key insight:** The agent's only input is the Linear issue. The issue
description, comments, labels, and attachments are everything the agent has
to work with. If it's not in the issue, the agent doesn't know about it.

### What the agent CAN do

- Read and understand code in any language
- Write, modify, and delete files
- Run shell commands (build, test, lint, etc.)
- Use git (branch, commit, push, merge conflicts)
- Use `gh` CLI (create PRs, add labels, read reviews)
- Read and write Linear comments (workpad updates, state transitions)
- Create follow-up issues for out-of-scope work
- Resolve merge conflicts with origin/main

### What the agent CANNOT do

- Access external services that require interactive auth (OAuth flows, SSO)
- Install system packages (no sudo)
- Access private APIs without credentials already in the environment
- Make product decisions — it follows the issue description literally
- Run GUI applications (no display server in the workspace)
- Ask you questions during execution — it's fully unattended

---

## Linear workspace setup

### Required states

Your Linear team must have these workflow states configured. Go to
**Settings > Teams > [Your Team] > Workflow** and ensure these exist:

| State | Type | Purpose |
|-------|------|---------|
| **Backlog** | Backlog | Issues not yet ready for agents. Agents ignore these entirely. |
| **Todo** | Unstarted or Started | Ready for an agent to pick up. This is the "ready" queue. |
| **In Progress** | Started | Agent is actively working on this issue. |
| **Human Review** | Started | Agent finished; PR is ready for human review. |
| **Merging** | Started | Human approved; agent is landing the PR. |
| **Rework** | Started | Human requested changes; agent will redo the work. |
| **Done** | Completed | PR merged, issue complete. |

**Critical:** "Human Review", "Merging", and "Rework" must exist as named
above. The agent uses exact string matching on state names for routing
decisions.

### phonyhuman config

The phonyhuman TOML config must include these active states:

```toml
active_states = ["Todo", "In Progress", "Merging", "Rework"]
```

Notice that **Human Review is NOT an active state**. This is intentional —
when an issue moves to Human Review, the agent stops and waits. It only
resumes when a human moves the issue to Merging (approved) or Rework
(changes needed).

### Project slug

All issues must be in the Linear project whose slug matches the
`project_slug` in the phonyhuman config. Issues in other projects are
invisible to phonyhuman.

---

## Issue lifecycle and states

Here is the full lifecycle of an issue through phonyhuman:

```
Backlog ──(human moves)──> Todo
                             │
                     agent picks up
                             │
                             v
                       In Progress
                             │
                    agent implements,
                    opens PR, validates
                             │
                             v
                       Human Review  <────────────┐
                             │                    │
                    human reviews PR              │
                             │                    │
                  ┌──────────┴──────────┐         │
                  │                     │         │
            (approved)            (needs changes) │
                  │                     │         │
                  v                     v         │
              Merging              Rework ────────┘
                  │                (agent closes PR,
           agent lands PR         starts fresh branch,
           (squash-merge)          re-implements)
                  │
                  v
                Done
```

### State transition rules

- **Backlog → Todo**: Human only. Move issues here when they are fully
  specified and ready for agent work.
- **Todo → In Progress**: Agent does this automatically on pickup.
- **In Progress → Human Review**: Agent does this after all acceptance
  criteria are met, PR checks are green, and feedback sweep is clean.
- **Human Review → Merging**: Human does this to approve.
- **Human Review → Rework**: Human does this to request changes.
- **Merging → Done**: Agent does this after successful squash-merge.
- **Rework → In Progress**: Agent handles this internally (closes old PR,
  creates fresh branch, starts over).

### What happens in each state

**Backlog**: Agent completely ignores. Use this for issues that need more
refinement, design discussion, or are blocked on external factors. Move to
Todo only when the issue is fully specified.

**Todo**: The moment an issue enters Todo, it enters the agent's pickup
queue. The agent will grab it within one polling cycle (typically 5–10
seconds). **Do not put issues in Todo unless they are ready to be worked
on immediately.**

**In Progress**: The agent is actively working. It will:
- Create a `## Codex Workpad` comment on the issue
- Write a hierarchical plan with acceptance criteria
- Sync the branch with origin/main
- Implement the changes
- Run validation/tests
- Commit, push, and open a PR
- Run a PR feedback sweep (check for review comments)
- Attach the PR to the issue

**Human Review**: The agent has stopped working. The PR is ready for
review. The agent will not make any changes until the issue moves to
Merging or Rework.

**Merging**: The agent picks the issue back up and runs the `land` skill:
- Checks for merge conflicts with main
- Monitors CI checks
- Addresses any review feedback
- Squash-merges when everything is green
- Moves to Done

**Rework**: The agent treats this as a full reset:
- Closes the existing PR
- Deletes the old workpad comment
- Creates a fresh branch from origin/main
- Starts over from scratch with a new plan
- Re-reads all comments (including your feedback)

---

## Writing issues agents can execute

The issue description is the agent's sole specification. Write it like you
are briefing a competent but literal-minded contractor who has never seen
your codebase before.

### The golden rules

1. **Be specific about the outcome, not the implementation.** Say what
   should happen, not how to code it (unless the how matters).
2. **Include file paths when you know them.** "Update the sidebar component"
   is vague. "Update `src/components/Sidebar.tsx`" is actionable.
3. **State the current behavior and the desired behavior.** For bugs, this
   is critical. For features, describe what exists today vs. what should
   exist after.
4. **Include example inputs and outputs.** If the feature processes data,
   show sample input → expected output.
5. **List what NOT to change.** If there are areas the agent should avoid
   touching, say so explicitly.
6. **Reference existing patterns.** "Follow the same pattern as
   `src/api/users.ts`" gives the agent a concrete template to follow.

### Issue description structure

Use this structure for every issue:

```markdown
## Summary

One or two sentences describing the change. What is being built/fixed and
why.

## Current Behavior

What happens today. For new features, describe the current state of the
relevant area (or "N/A — new feature").

## Desired Behavior

What should happen after this issue is implemented. Be specific and
testable.

## Requirements

- Bullet list of specific requirements
- Each requirement should be independently verifiable
- Include edge cases that matter
- Include error handling expectations

## Files / Areas of Interest

- `src/components/Foo.tsx` — main component to modify
- `src/api/bar.ts` — API client that may need updates
- `tests/foo.test.ts` — existing tests to update

## Out of Scope

- Do NOT modify the database schema
- Do NOT change the authentication flow
- Styling changes are not needed for this ticket

## Validation

- [ ] `npm test` passes
- [ ] `npm run build` succeeds
- [ ] Manual verification: navigate to /settings, toggle dark mode,
      confirm all components render correctly

## Test Plan

- [ ] Add unit test for `DarkModeToggle` component
- [ ] Add integration test for theme persistence across page reload
- [ ] Verify existing tests still pass
```

### The Validation section is sacred

If you include a section called `Validation`, `Test Plan`, or `Testing` in
the issue description, the agent treats it as **non-negotiable acceptance
criteria**. The agent will:

1. Copy these items into its workpad as required checkboxes.
2. Execute every item before considering the work complete.
3. Not move to Human Review until all items pass.

This is your most powerful quality lever. Use it.

### Description anti-patterns

**Too vague:**
> "Make the app faster"

The agent will guess what to optimize and probably pick something you
didn't intend.

**Too prescriptive about implementation:**
> "In line 47 of server.js, change the timeout from 5000 to 10000"

This might work, but it's fragile. Better: "Increase the API request
timeout to handle slow upstream responses. The current 5s timeout causes
failures for large dataset queries."

**Missing context:**
> "Fix the login bug"

Which login bug? What's the error? What's the expected behavior? The agent
will spend turns investigating instead of fixing.

**Assumes knowledge:**
> "Do the same thing we did for the users endpoint"

The agent doesn't know what "the same thing" was. Reference specific files
or commits instead.

---

## Acceptance criteria

Acceptance criteria should be written as a checklist of independently
verifiable statements. They go in the issue description, ideally in a
dedicated `## Acceptance Criteria` or `## Requirements` section.

### Good acceptance criteria

```markdown
## Acceptance Criteria

- [ ] Dark mode toggle appears in the settings page header
- [ ] Clicking the toggle switches between light and dark themes
- [ ] Theme preference persists across browser sessions (localStorage)
- [ ] All existing components render correctly in both themes
- [ ] No console errors when switching themes
- [ ] Toggle is keyboard-accessible (Enter/Space to activate)
```

### Bad acceptance criteria

```markdown
## Acceptance Criteria

- [ ] It works
- [ ] Looks good
- [ ] No bugs
```

These are unverifiable. The agent has no way to determine if "it works" or
"looks good" and will either skip validation or make up arbitrary tests.

### Acceptance criteria tips

- Use action verbs: "displays", "returns", "prevents", "persists"
- Include negative cases: "does NOT allow empty submissions"
- Reference specific UI elements or API responses
- Include performance expectations if relevant: "page loads in under 2s"
- For API changes, include example request/response pairs

---

## Validation and test plans

The `Validation` section is distinct from acceptance criteria. Acceptance
criteria say WHAT should be true. Validation says HOW to verify it.

### Effective validation sections

```markdown
## Validation

- [ ] `npm test` passes with no failures
- [ ] `npm run build` produces no errors or warnings
- [ ] `npm run lint` passes
- [ ] Start dev server (`npm run dev`), navigate to /settings, confirm
      toggle renders
- [ ] In browser console, verify no errors on theme switch
```

### Validation for different project types

**Node.js / React / Vite:**
```markdown
- [ ] `npm test` passes
- [ ] `npm run build` succeeds
- [ ] `npm run lint` passes
```

**Rust / Tauri:**
```markdown
- [ ] `cargo test` passes
- [ ] `cargo build --release` succeeds
- [ ] `cargo clippy -- -D warnings` passes
```

**Python:**
```markdown
- [ ] `pytest` passes
- [ ] `mypy .` passes
- [ ] `ruff check .` passes
```

**Go:**
```markdown
- [ ] `go test ./...` passes
- [ ] `go build ./...` succeeds
- [ ] `golangci-lint run` passes
```

**Elixir:**
```markdown
- [ ] `mix test` passes
- [ ] `mix compile --warnings-as-errors` succeeds
- [ ] `mix credo` passes
```

### When the agent can't validate

Some validation requires things the agent doesn't have access to:

- **No display server**: The agent can't open a browser or GUI app. It can
  build and run tests, but can't visually verify UI rendering.
- **No sudo**: Can't install system packages. If a build requires system
  deps that aren't installed, the agent will note this in the workpad and
  rely on CI.
- **No external services**: If validation requires hitting a live API,
  staging server, or database, provide mock data or test fixtures.

For these cases, write validation that the agent CAN do, and note what
requires human verification:

```markdown
## Validation

- [ ] `npm run build` succeeds (agent can verify)
- [ ] `npm test` passes (agent can verify)
- [ ] Visual: dark mode toggle renders correctly (human verify in PR review)
- [ ] Visual: all pages render in dark mode without artifacts (human verify)
```

---

## Dependencies and ordering

phonyhuman respects Linear's `blockedBy` / `blocking` relationships for
issues in the **Todo** state.

### How dependency blocking works

- If Issue B is `blockedBy` Issue A, and Issue A is NOT in a terminal state
  (Done, Closed, Cancelled), then Issue B **will not be picked up** by any
  agent, even if it's in Todo.
- Once Issue A reaches Done (or another terminal state), Issue B becomes
  eligible for pickup.
- Dependencies are only enforced for **Todo** issues. If you manually move
  a blocked issue to In Progress, the agent will work on it regardless.

### When to use dependencies

Use `blockedBy` when:

- Issue B literally cannot be implemented without Issue A's code being
  merged first (e.g., B builds on an API that A creates).
- Issue B's tests would fail without Issue A's changes.
- Issue B modifies the same files as Issue A and would cause merge
  conflicts.

Do NOT use `blockedBy` when:

- The issues touch different parts of the codebase and can be implemented
  in parallel.
- The dependency is soft/preferential rather than technical.
- You just want issues done in a particular order for product reasons (use
  priority instead).

### Setting up a dependency chain

In Linear:

1. Open Issue B
2. Click "Add relation" → "Is blocked by" → select Issue A
3. Issue B will show "Blocked by A" in its sidebar

The agent will see this and wait.

### Parallel vs. sequential

**Can run in parallel** (no dependency needed):
- "Add dark mode toggle" + "Add user avatar upload" (different features,
  different files)
- "Fix login timeout" + "Add password reset" (different flows)

**Must be sequential** (use blockedBy):
- "Create User API endpoint" → "Add user list page that calls User API"
- "Add database migration for roles" → "Implement role-based permissions"
- "Refactor auth module" → "Add OAuth provider" (OAuth depends on new auth
  structure)

---

## Sizing and scoping for agents

Agents work best with well-scoped, focused issues. Here are guidelines for
sizing.

### Ideal issue size

- **1–5 files modified** (agent can hold full context)
- **Clear, single responsibility** (one feature, one bug fix, one refactor)
- **Verifiable in isolation** (tests can run without other pending work)
- **Completable in 10–15 agent turns** (roughly 30–60 minutes wall clock)

### Too small

Issues that are trivially small add overhead without value:
- "Fix typo in README" — just fix it yourself
- "Update a single dependency" — do it in a batch
- "Change one CSS color value" — not worth the agent setup time

### Too large

Issues that are too large cause agents to run out of context or turns:
- "Rewrite the entire authentication system" — break into pieces
- "Add a complete admin dashboard" — decompose into individual pages/features
- "Migrate from REST to GraphQL" — scope to individual endpoints

### Breaking down large features

When a feature is too large for one issue, decompose it:

1. **Vertical slicing**: Each issue delivers a thin, end-to-end slice of
   functionality.
   - Bad: "Backend for feature X" + "Frontend for feature X"
   - Good: "Add create user flow (API + form + tests)" + "Add edit user
     flow (API + form + tests)"

2. **Infrastructure first**: If the feature needs shared infrastructure,
   make that Issue A with everything else blocked by it.
   - Issue A: "Add base API client with auth" (blockedBy: nothing)
   - Issue B: "Add user CRUD endpoints" (blockedBy: A)
   - Issue C: "Add user list page" (blockedBy: B)

3. **One concern per issue**: Don't mix refactoring with feature work.
   - Issue A: "Refactor form validation to use Zod" (blockedBy: nothing)
   - Issue B: "Add registration form with validation" (blockedBy: A)

---

## Labels and metadata

### The `symphony` label

The agent automatically adds a `symphony` label to every PR it creates.
This is used for filtering and identifying agent-created PRs. You don't
need to add this label to issues — the agent handles it on the PR side.

### Priority

Linear priorities (Urgent, High, Medium, Low, No Priority) affect pickup
order. phonyhuman dispatches higher-priority issues first when multiple
Todo issues are available simultaneously.

Priority order: Urgent > High > Medium > Low > No Priority

Within the same priority level, older issues (by creation date) are picked
up first.

### Assignee

By default, phonyhuman picks up any unassigned issue in the project that's
in an active state. If the phonyhuman config includes an `assignee` filter,
only issues assigned to that user will be picked up.

For Sprint Planning: either leave issues unassigned (agent picks up
anything) or assign them to a designated "bot" user if you want to control
which issues go to agents vs. humans.

### Estimates

Estimates on Linear issues don't affect agent behavior, but they're useful
for Sprint Planning velocity tracking. A rough guide for agent work:

| Estimate | Typical scope |
|----------|--------------|
| 1 point | Single file change, simple bug fix, config update |
| 2 points | 2-3 file changes, straightforward feature, test additions |
| 3 points | 3-5 file changes, feature with edge cases, API + frontend |
| 5 points | Consider breaking down — getting large for one agent pass |
| 8+ points | Definitely break down into smaller issues |

---

## Multi-issue features and epics

### Using Linear projects and sub-issues

For large features spanning multiple issues:

1. Create a parent issue or use a Linear project to group related issues.
2. Break the feature into ordered issues with `blockedBy` relationships.
3. Put all issues in **Backlog** initially.
4. During Sprint Planning, move the batch to **Todo** (respecting
   dependency order — blocked issues won't be picked up until their
   blockers are done).

### Example: "Add user authentication"

```
Epic: User Authentication

Issue 1: Add auth database schema and models          [Todo]
  - Create users table migration
  - Add User model with password hashing
  - Validation: migration runs, model tests pass

Issue 2: Add registration API endpoint                [Todo, blockedBy: 1]
  - POST /api/auth/register
  - Input validation, duplicate email check
  - Validation: API tests pass, curl example works

Issue 3: Add login API endpoint                       [Todo, blockedBy: 1]
  - POST /api/auth/login
  - JWT token generation
  - Validation: API tests pass, returns valid JWT

Issue 4: Add registration page                        [Todo, blockedBy: 2]
  - React form with email/password fields
  - Error handling for validation failures
  - Validation: npm test, npm build, form submits to API

Issue 5: Add login page                               [Todo, blockedBy: 3]
  - React form, JWT storage in localStorage
  - Redirect to dashboard on success
  - Validation: npm test, npm build, login flow works

Issue 6: Add auth middleware                           [Todo, blockedBy: 3]
  - Protect routes that require authentication
  - Return 401 for missing/invalid tokens
  - Validation: middleware tests pass
```

Issues 2 and 3 can run in parallel (both only depend on 1).
Issues 4 and 5 can run in parallel (depend on 2 and 3 respectively).
Issue 6 can run in parallel with 4 and 5.

### Coordination between agents

Multiple agents can work on different issues simultaneously. They work in
isolated workspaces (separate git worktrees), so they don't interfere with
each other's code. When an agent pushes a PR and it gets merged, the next
agent will pick up those changes when it syncs with origin/main.

This means:
- No merge conflicts between parallel agents (they work on separate
  branches)
- Each agent sees the latest merged code when it starts or syncs
- Dependencies ensure agents don't start work before prerequisite code is
  merged

---

## The human review loop

### What to look for in agent PRs

The agent's PR will include:
- A descriptive title summarizing the change
- A body with summary, rationale, and test plan
- The `symphony` label
- A link back to the Linear issue

On the Linear issue, the `## Codex Workpad` comment shows:
- The agent's plan (what it intended to do)
- Acceptance criteria (what it verified)
- Validation results (what commands it ran and their outcomes)
- Notes (any issues encountered, assumptions made)
- Confusions (anything unclear — pay special attention to these)

### Review checklist for agent PRs

1. **Does the code match the issue requirements?** Compare the diff against
   the issue description.
2. **Are tests adequate?** The agent writes tests but may miss edge cases
   you care about.
3. **Are there any Confusions in the workpad?** These indicate areas where
   the agent was unsure — review these carefully.
4. **Does the code follow project conventions?** The agent tries to match
   existing patterns but may deviate.
5. **Are there any security concerns?** The agent avoids common
   vulnerabilities but a human eye is important.
6. **Did CI pass?** Check the PR checks.

### After review

- **Approve**: Move the Linear issue to **Merging**. The agent will
  squash-merge the PR automatically.
- **Request changes**: Move the Linear issue to **Rework**. Add a comment
  on the Linear issue (not just the PR) explaining what needs to change.
  The agent will close the PR, start fresh, and incorporate your feedback.
- **Add PR comments**: If you add review comments on the PR while the issue
  is still in Human Review, the agent won't see them until it resumes. For
  the agent to address PR feedback, move to Rework.

### Important: where to leave feedback

- **Linear issue comments**: The agent reads these when it starts or
  resumes work. Best for high-level feedback, requirement clarifications,
  or "do it differently" instructions.
- **GitHub PR comments**: The agent reads these during PR feedback sweeps.
  Good for code-level feedback (inline comments on specific lines).
- **Both**: For Rework, comment on both the Linear issue (what to change)
  and the PR (specific code feedback) before moving to Rework.

---

## Rework and feedback

### How Rework works

When you move an issue to **Rework**:

1. The agent picks it up on the next polling cycle.
2. It **closes the existing PR** — the old code is abandoned.
3. It **deletes the old workpad comment** — clean slate.
4. It **creates a fresh branch from origin/main**.
5. It **re-reads the full issue body and ALL comments** — including your
   feedback.
6. It **explicitly identifies what to do differently** this time.
7. It starts over from scratch with a new plan.

### Writing effective rework feedback

Since the agent re-reads everything from scratch, your feedback should be
clear and specific:

**Good rework feedback (as a Linear comment):**
> The approach of using localStorage for auth tokens is insecure. Use
> httpOnly cookies instead. The registration form should also include a
> "confirm password" field. See the existing password reset flow in
> `src/pages/ResetPassword.tsx` for the cookie-based auth pattern to
> follow.

**Bad rework feedback:**
> This isn't right. Please fix.

The agent will try its best with vague feedback, but it may make the same
mistakes or different ones. Specific, actionable feedback with file
references produces the best rework results.

### Rework vs. new issue

Use **Rework** when:
- The implementation approach was wrong
- Requirements were misunderstood
- Code quality is below the bar across the PR

Create a **new issue** when:
- The PR is fine but you want additional features
- You want incremental improvements on top of merged code
- The feedback is really a new requirement, not a fix

---

## Common pitfalls

### 1. Moving to Todo before the issue is fully specified

The agent picks up Todo issues within seconds. If the description is
incomplete, the agent will work with what it has and likely produce
something you didn't want. Keep issues in Backlog until they're ready.

### 2. Vague or missing validation section

Without a `Validation` section, the agent decides on its own what to test.
It usually runs the obvious commands (`npm test`, `cargo test`), but it
may miss project-specific validation that matters to you.

### 3. Not setting up dependencies for sequential work

If Issue B depends on Issue A's code, but you don't set `blockedBy`, both
agents will start simultaneously. Issue B's agent will work against
origin/main (which doesn't have A's changes yet), and the resulting PR
will likely have conflicts or missing dependencies.

### 4. Putting too many issues in Todo at once

phonyhuman has a `max_concurrent` setting (default: 5). If you move 20
issues to Todo, only 5 agents will run at a time. The rest queue up. This
is fine, but be aware that issues are picked up by priority, then by
creation date — not by the order you moved them to Todo.

### 5. Expecting the agent to ask clarifying questions

The agent is fully unattended. It cannot ask you questions. If something
is ambiguous, it will make its best guess and note any confusions in the
workpad. Write unambiguous issues.

### 6. Leaving issues in Human Review too long

While an issue is in Human Review, the agent is idle. The workspace and
branch still exist. If you leave many issues in Human Review, you're
consuming workspace resources without progress. Review promptly.

### 7. Commenting on an issue in Human Review and expecting the agent to act

The agent does NOT watch for comments in Human Review. It's stopped. To
get the agent to act on your feedback, move the issue to **Rework**.

### 8. Not accounting for system dependencies

If your project requires system-level packages (like GTK dev libraries for
Tauri, or native extensions), the agent workspace may not have them. The
agent can't `sudo apt-get install`. Either:
- Ensure the build host has all deps pre-installed
- Write validation that works without the full native build (e.g., just
  `cargo check` instead of `cargo build`)
- Let CI handle the native build and have the agent focus on code
  correctness

### 9. Mixing refactoring with feature work

Large refactors mixed with feature work create hard-to-review PRs and
increase the chance of agent confusion. Separate them into distinct issues
with the refactor blocking the feature.

### 10. Not checking the workpad

The workpad is the agent's thinking process. If a PR looks wrong, read the
workpad first — it often explains why the agent made certain choices and
reveals misunderstandings you can correct in rework feedback.

---

## Issue templates

### Bug fix template

```markdown
## Summary

[Component/feature] is [broken behavior]. Expected: [correct behavior].

## Current Behavior

Steps to reproduce:
1. Navigate to [page/endpoint]
2. Perform [action]
3. Observe: [what actually happens]

Error message (if any):
```
[paste error message or stack trace]
```

## Desired Behavior

After [same steps], [what should happen instead].

## Requirements

- [ ] Fix [root cause description]
- [ ] Preserve existing behavior for [related functionality]
- [ ] Add test case that reproduces the bug and verifies the fix
- [ ] No regressions in [related area]

## Files of Interest

- `src/path/to/likely-cause.ts` — probable location of the bug
- `tests/path/to/related.test.ts` — existing tests for this area

## Out of Scope

- Do not refactor surrounding code
- Do not change [related feature]

## Validation

- [ ] `npm test` passes
- [ ] New test case specifically tests the fix
- [ ] [Reproduction steps] now produce correct behavior
```

### Feature template

```markdown
## Summary

Add [feature name] to [area of the app]. This allows users to [user-facing
benefit].

## Current Behavior

Currently, [what exists today]. Users cannot [what they need].

## Desired Behavior

After this change:
- [Specific behavior 1]
- [Specific behavior 2]
- [Specific behavior 3]

## Requirements

- [ ] [Requirement 1 with specific details]
- [ ] [Requirement 2 with specific details]
- [ ] [Error handling: what happens when X fails]
- [ ] [Edge case: what happens when Y is empty/null/large]

## UI/UX Details (if applicable)

- [Component] should be placed [where]
- [Interaction] should behave like [reference]
- Follow existing patterns in `src/components/[similar component]`

## API Changes (if applicable)

New endpoint:
- `POST /api/[resource]`
- Request body: `{ "field": "value" }`
- Success response: `{ "id": "...", "field": "value" }`
- Error response: `{ "error": "message" }`

## Files of Interest

- `src/components/[area]/` — where new component should live
- `src/api/[area].ts` — API client to extend
- `src/types/[area].ts` — types to add

## Out of Scope

- [Related feature that should be a separate issue]
- [Nice-to-have that can come later]

## Acceptance Criteria

- [ ] [Testable criterion 1]
- [ ] [Testable criterion 2]
- [ ] [Testable criterion 3]

## Validation

- [ ] `npm test` passes
- [ ] `npm run build` succeeds
- [ ] `npm run lint` passes
- [ ] [Specific manual verification steps]

## Test Plan

- [ ] Unit tests for [component/function]
- [ ] Integration tests for [flow/endpoint]
- [ ] Existing tests pass without modification
```

### Refactor template

```markdown
## Summary

Refactor [area/module] to [improvement goal]. No behavior changes.

## Motivation

Current code [problem: duplication/complexity/poor patterns]. This
refactor [benefit: simplifies, enables future work, improves
maintainability].

## Requirements

- [ ] [Specific refactoring action 1]
- [ ] [Specific refactoring action 2]
- [ ] Zero behavior changes — all existing tests must pass unchanged
- [ ] No new dependencies

## Files to Modify

- `src/path/to/file1.ts` — [what changes]
- `src/path/to/file2.ts` — [what changes]

## Out of Scope

- Do not add new features during this refactor
- Do not change public API signatures

## Validation

- [ ] All existing tests pass without modification
- [ ] `npm run build` succeeds
- [ ] `npm run lint` passes
- [ ] No behavior changes (same inputs produce same outputs)
```

---

## Sprint Planning checklist

Use this checklist during Sprint Planning to ensure all issues are ready
for agent pickup:

### For each issue

- [ ] **Description is complete** — summary, current behavior, desired
      behavior, requirements
- [ ] **Acceptance criteria are specific and testable** — no vague
      "it works" criteria
- [ ] **Validation section is present** — concrete commands the agent
      should run
- [ ] **Files of interest are listed** — helps the agent find the right
      code faster
- [ ] **Out of scope is defined** — prevents the agent from going on
      tangents
- [ ] **Dependencies are set** — `blockedBy` for any issue that requires
      another's code to be merged first
- [ ] **Priority is set** — determines pickup order when multiple issues
      are in Todo
- [ ] **Issue is in the correct project** — must match phonyhuman's
      `project_slug`
- [ ] **State is Backlog** — do NOT move to Todo until Sprint Planning is
      complete and all issues are reviewed

### For the sprint as a whole

- [ ] **Dependency graph is acyclic** — no circular dependencies
- [ ] **Parallel work is identified** — independent issues can run
      simultaneously
- [ ] **max_concurrent is appropriate** — enough agents for the parallel
      work, but not so many that the build host is overwhelmed
- [ ] **System dependencies are installed** — the build host has all
      required dev libraries
- [ ] **Build commands are documented** — if the project has unusual build
      steps, include them in the validation section of each issue
- [ ] **CI is configured** — agents will push PRs; CI should run on them
- [ ] **Team knows the review process** — who reviews agent PRs, how
      quickly, and the Merging/Rework flow

### After Sprint Planning

1. Move all sprint issues from **Backlog** to **Todo** at once (or in
   dependency order if you prefer controlled rollout).
2. phonyhuman picks them up automatically.
3. Monitor progress via Linear (workpad comments), GitHub (PRs), or the
   web dashboard.
4. Review PRs as they arrive in Human Review.
5. Move approved issues to Merging.
6. Move issues needing changes to Rework with clear feedback.

---

## Quick reference card

| Question | Answer |
|----------|--------|
| Where does the agent get its instructions? | Linear issue description + comments |
| When does the agent start? | When the issue enters Todo state |
| When does the agent stop? | When it moves to Human Review, Done, or a terminal state |
| How do I approve? | Move issue to Merging in Linear |
| How do I request changes? | Add feedback comment, move issue to Rework |
| How do I block an issue? | Keep it in Backlog, or use blockedBy |
| How do I prioritize? | Set Linear priority (Urgent > High > Medium > Low) |
| How do I see progress? | Read the Codex Workpad comment on the issue |
| Can agents work in parallel? | Yes, up to max_concurrent (default: 5) |
| What if the agent gets stuck? | It will note blockers in the workpad and move to Human Review |
| Can I comment during In Progress? | Yes, but the agent may not see it until next sync |
| What repo states are needed? | Todo, In Progress, Human Review, Merging, Rework, Done |
