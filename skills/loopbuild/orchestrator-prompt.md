# Orchestrator Prompt

This prompt is fed back to you each iteration by the Stop hook. It drives ALL orchestrator behavior. Follow it exactly.

## Step 1: Read State

Before taking any action, read the current state:

1. Read `.claude/loop-orchestrator/status.json` — get current phase, iteration, unit counts
2. Read `.claude/loop-orchestrator/config.json` — get max_concurrent, max_retries, test_command, start_command, has_ui
3. Read every unit status file under `.claude/loop-orchestrator/units/*/status.json` — get per-unit status, retries, errors

Do not proceed until you have read ALL state files. Decisions without current state cause cascading failures.

## Step 2: Execute Based on Phase

### Phase: EXECUTING

1. **Count units by status:** tally pending, in_progress, done, blocked units
2. **Dispatch pending units** if there is capacity (in_progress < max_concurrent):
   - For each unit to dispatch, read its `context.md` for scope, tasks, and Definition of Done
   - Read the subagent prompt template from `${CLAUDE_PLUGIN_ROOT}/skills/loopbuild/subagent-prompt.md`
   - Read `.claude/loop-orchestrator/interfaces.md` and `.claude/loop-orchestrator/decisions.md`
   - Perform literal string replacement of all `{{variables}}` in the template with actual content from the state files:
     - `{{unit_name}}` — from the unit's status.json `name` field
     - `{{unit_scope}}` — from the unit's context.md Scope section
     - `{{interfaces_md_content}}` — full content of interfaces.md
     - `{{decisions_md_content}}` — full content of decisions.md
     - `{{unit_tasks_from_context_md}}` — the Tasks section from the unit's context.md
     - `{{unit_dod_from_context_md}}` — the Definition of Done section from the unit's context.md
     - `{{retry_context}}`, `{{retry_number}}`, `{{max_retries}}`, `{{last_error}}` — from unit status.json (only if retrying)
   - Pass the rendered prompt as the `prompt` parameter to the Agent tool with `isolation: "worktree"` and `mode: "bypassPermissions"`
   - The Agent tool returns the worktree path and branch in its result when `isolation: "worktree"` is used. Record these in the unit's status.json. If the worktree path is not returned, discover it via `git worktree list` and match by the unit's branch name.
   - Update the unit's status.json: set `status` to `"in_progress"`, record `worktree_path` and `branch`
3. **Process returned subagents:**
   - **Success** — set unit status to `"done"`, update `simplify_done` and `review_done` flags, increment `units_completed` in status.json
   - **Failure with retries remaining** — increment `retries`, record `last_error`, set status back to `"pending"` for re-dispatch next iteration
   - **Failure with retries exhausted** — set status to `"blocked"`, increment `units_blocked` in status.json, report to user with the error details
4. **Check transition:** if all units are `done` or `blocked`, and at least one is `done`, transition to MERGING. Update `status.json` phase to `"merging"`.

### Phase: MERGING

1. Run the merge script:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge-worktrees.sh"
   ```
2. Handle exit codes:
   - **Exit 0** — all merges succeeded and tests passed. Transition to REVIEWING. Update `status.json` phase to `"reviewing"`.
   - **Exit 1** — merge conflicts occurred. Report conflicting units to the user. The merge script marks conflicting units with `status: "merge_conflict"` in their status.json. Escalate to user for resolution guidance.
   - **Exit 2** — merges succeeded but tests failed after merge. Report the test failure output. The integrated code has a problem that needs fixing. Escalate to user.

### Phase: REVIEWING

1. **Run /simplify** on the full merged codebase. This is a quality gate, not a correctness gate. If the /simplify skill is unavailable, log a warning and skip: "WARNING: /simplify not available, skipping codebase simplification."
2. **Run code-review** on the full diff (`git diff <base_branch>...HEAD`). This is also a quality gate. If the code-review skill is unavailable, log a warning and skip: "WARNING: code-review not available, skipping full-diff review."
3. If either review surfaces issues:
   - Fix the issues found
   - Re-run the review that found them (max 2 rounds total)
   - If issues persist after 2 rounds, log them and proceed
4. Transition: if `has_ui` is `true` in config.json, update phase to `"verifying"`. Otherwise, update phase to `"done"`.

### Phase: VERIFYING

This phase only runs when `has_ui` is `true`.

1. **Read acceptance tests** from `.claude/loop-orchestrator/acceptance-tests.md`
2. **Write Playwright test files** translating the natural-language scenarios into executable Playwright tests. Save to `tests/e2e/acceptance.spec.ts` (or the project's existing test directory).
3. **Auto-generate smoke tests** for routes not covered by acceptance tests:
   - Detect the framework: check for Next.js (`next.config.*`), Remix (`remix.config.*`), Vite (`vite.config.*`), Express (`app.listen` or `express()` patterns)
   - Enumerate routes from file-based routing (e.g., `app/` or `pages/` directory) or explicit route definitions
   - Diff enumerated routes against routes already covered by acceptance tests
   - For each uncovered route, generate a load-and-check smoke test: navigate to the route, assert HTTP 200, assert no console errors
   - Save to `tests/e2e/smoke.spec.ts`
4. **Start the application:**
   ```bash
   <start_command from config.json> &
   ```
   Wait for the app to be ready (poll the health endpoint or wait for the port to be listening).
5. **Install Playwright** if not already available:
   ```bash
   npx playwright install --with-deps chromium
   ```
6. **Run all Playwright tests:**
   ```bash
   npx playwright test
   ```
7. **Handle results:**
   - All pass — transition to DONE. Update `status.json` phase to `"done"`.
   - Failures — analyze each failure (is it a test issue or a code issue?), fix, re-run. Max 3 rounds of fix-and-rerun.
   - Still failing after 3 rounds — escalate to user with failure details, screenshots, and error logs. Do not transition to DONE.

### Phase: DONE

1. Output a completion summary:
   - Total units completed vs total
   - Total iterations used
   - Blocked units (if any) with their error details
   - Time elapsed (from `started_at` in status.json to now)
   - Whether /simplify and code-review were run
   - Whether Playwright verification passed (if applicable)
2. Output `<promise>LOOP COMPLETE</promise>` to signal the Stop hook to allow session exit.

## Step 3: Output Status

Every iteration, output a status block:

```
Loop iteration <N> | Phase: <PHASE> | <completed>/<total> units done, <in_progress> in progress
  <unit-01-name>: <STATUS> (<detail>)
  <unit-02-name>: <STATUS> (<detail>)
  ...
```

Include relevant detail per unit: task progress, retry count, error summary, or "dispatched iteration N".

## Rules

- **Read state first.** Never take action based on assumptions. Always read status.json and all unit files at the start of each iteration.
- **Update state after every action.** Every dispatch, completion, failure, retry, and phase transition must be reflected in the state files immediately.
- **Never exceed max_concurrent.** Count in_progress units before dispatching. Only dispatch enough to fill remaining capacity.
- **Always use isolation: "worktree"** when dispatching subagents via the Agent tool. Never dispatch subagents without worktree isolation.
- **Ask the user when uncertain.** If a merge conflict, persistent test failure, or ambiguous situation arises that the rules above don't clearly cover, escalate to the user rather than guessing.
