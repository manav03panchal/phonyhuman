---
name: land
description:
  Land a PR by monitoring conflicts, resolving them, waiting for checks, and
  squash-merging when green; use when asked to land, merge, or shepherd a PR to
  completion.
---

# Land

## Goals

- Ensure the PR is conflict-free with main.
- Keep CI green and fix failures when they occur.
- Squash-merge the PR once checks pass.
- Do not yield to the user until the PR is merged; keep the watcher loop running
  unless blocked.
- No need to delete remote branches after merge; the repo auto-deletes head
  branches.

## Preconditions

- `gh` CLI is authenticated.
- You are on the PR branch with a clean working tree.

## Steps

1. Locate the PR for the current branch.
2. Run project tests/lint locally before any push (follow repo conventions).
3. If the working tree has uncommitted changes, commit with the `commit` skill
   and push with the `push` skill before proceeding.
4. Check mergeability and conflicts against main.
5. If conflicts exist, use the `pull` skill to fetch/merge `origin/main` and
   resolve conflicts, then use the `push` skill to publish the updated branch.
6. Ensure review comments (if present) are acknowledged and any required
   fixes are handled before merging.
7. Watch checks until complete.
8. If checks fail, pull logs, fix the issue, commit with the `commit` skill,
   push with the `push` skill, and re-run checks.
9. When all checks are green and review feedback is addressed, squash-merge and
   delete the branch using the PR title/body for the merge subject/body.
10. **Context guard:** Before implementing review feedback, confirm it does not
    conflict with the user's stated intent or task context. If it conflicts,
    respond inline with a justification and ask the user before changing code.
11. **Pushback template:** When disagreeing, reply inline with: acknowledge +
    rationale + offer alternative.
12. **Ambiguity gate:** When ambiguity blocks progress, use the clarification
    flow (assign PR to current GH user, mention them, wait for response). Do not
    implement until ambiguity is resolved.
    - If you are confident you know better than the reviewer, you may proceed
      without asking the user, but reply inline with your rationale.
13. **Per-comment mode:** For each review comment, choose one of: accept,
    clarify, or push back. Reply inline (or in the issue thread for bot
    reviews) stating the mode before changing code.
14. **Reply before change:** Always respond with intended action before pushing
    code changes.

## Commands

```
# Ensure branch and PR context
branch=$(git branch --show-current)
pr_number=$(gh pr view --json number -q .number)
pr_title=$(gh pr view --json title -q .title)
pr_body=$(gh pr view --json body -q .body)

# Check mergeability and conflicts
mergeable=$(gh pr view --json mergeable -q .mergeable)

if [ "$mergeable" = "CONFLICTING" ]; then
  # Run the `pull` skill to handle fetch + merge + conflict resolution.
  # Then run the `push` skill to publish the updated branch.
fi

# Preferred: use the Async Watch Helper below. The manual loop is a fallback
# when Python cannot run or the helper script is unavailable.
# Wait for review feedback and CI checks.
while true; do
  # Check for review comments
  gh api repos/{owner}/{repo}/issues/"$pr_number"/comments \
    --jq '.[] | select(.body | startswith("## ")) | .id' | head -1 \
    && break
  sleep 10
done

# Watch checks
if ! gh pr checks --watch; then
  gh pr checks
  # Identify failing run and inspect logs
  # gh run list --branch "$branch"
  # gh run view <run-id> --log
  exit 1
fi

# Squash-merge (remote branches auto-delete on merge in this repo)
gh pr merge --squash --subject "$pr_title" --body "$pr_body"
```

## Async Watch Helper

Preferred: use the asyncio watcher to monitor review comments, CI, and head
updates in parallel:

```
python3 <skills_dir>/land/land_watch.py
```

Where `<skills_dir>` is the absolute path to the skills directory provided in the
workflow prompt (the same directory containing this SKILL.md file).

Exit codes:

- 2: Review comments detected (address feedback)
- 3: CI checks failed
- 4: PR head updated (autofix commit detected)
- 5: PR has merge conflicts

## Failure Handling

- If checks fail, pull details with `gh pr checks` and `gh run view --log`, then
  fix locally, commit with the `commit` skill, push with the `push` skill, and
  re-run the watch.
- Use judgment to identify flaky failures. If a failure is a flake (e.g., a
  timeout on only one platform), you may proceed without fixing it.
- If CI pushes an auto-fix commit (authored by GitHub Actions), it does not
  trigger a fresh CI run. Detect the updated PR head, pull locally, merge
  `origin/main` if needed, add a real author commit, and force-push to retrigger
  CI, then restart the checks loop.
- If mergeability is `UNKNOWN`, wait and re-check.
- Do not merge while review comments (human or bot) are outstanding.
- Do not enable auto-merge; use explicit squash-merge after checks pass.
- If the remote PR branch advanced due to your own prior force-push or merge,
  avoid redundant merges; re-run the formatter locally if needed and
  `git push --force-with-lease`.

## Review Handling

- Human review comments are blocking and must be addressed (responded to and
  resolved) before requesting a new review or merging.
- If multiple reviewers comment in the same thread, respond to each comment
  (batching is fine) before closing the thread.
- Fetch review comments via `gh api` and reply with a prefixed comment.
- Use review comment endpoints (not issue comments) to find inline feedback:
  - List PR review comments:
    ```
    gh api repos/{owner}/{repo}/pulls/<pr_number>/comments
    ```
  - PR issue comments (top-level discussion):
    ```
    gh api repos/{owner}/{repo}/issues/<pr_number>/comments
    ```
  - Reply to a specific review comment:
    ```
    gh api -X POST /repos/{owner}/{repo}/pulls/<pr_number>/comments \
      -f body='[agent] <response>' -F in_reply_to=<comment_id>
    ```
- `in_reply_to` must be the numeric review comment id (e.g., `2710521800`), not
  the GraphQL node id (e.g., `PRRC_...`), and the endpoint must include the PR
  number (`/pulls/<pr_number>/comments`).
- If GraphQL review reply mutation is forbidden, use REST.
- A 404 on reply typically means the wrong endpoint (missing PR number) or
  insufficient scope; verify by listing comments first.
- All GitHub comments generated by this agent must be prefixed with `[agent]`.
- If feedback requires changes:
  - For inline review comments (human), reply with intended fixes
    (`[agent] ...`) **as an inline reply to the original review comment** using
    the review comment endpoint and `in_reply_to` (do not use issue comments for
    this).
  - Implement fixes, commit, push.
  - Reply with the fix details and commit sha (`[agent] ...`) in the same place
    you acknowledged the feedback.

## Scope + PR Metadata

- The PR title and description should reflect the full scope of the change, not
  just the most recent fix.
- If review feedback expands scope, decide whether to include it now or defer
  it. You can accept, defer, or decline feedback. If deferring or declining,
  call it out in the root-level `[agent]` update with a brief reason (e.g.,
  out-of-scope, conflicts with intent, unnecessary).
- Correctness issues raised in review comments should be addressed. If you plan
  to defer or decline a correctness concern, validate first and explain why the
  concern does not apply.
- Classify each review comment as one of: correctness, design, style,
  clarification, scope.
- For correctness feedback, provide concrete validation (test, log, or
  reasoning) before closing it.
- When accepting feedback, include a one-line rationale in the root-level
  update.
- When declining feedback, offer a brief alternative or follow-up trigger.
- Prefer a single consolidated "review addressed" root-level comment after a
  batch of fixes instead of many small updates.
