---
name: loopbuild
description: Execute a /loopplan via orchestrated parallel subagents in worktrees. Use when the user runs /loopbuild, wants to "execute the loop plan", "start the orchestrator", "run parallel build", or references a loop plan file.
---

I'm using the loopbuild skill to orchestrate parallel execution of this plan.

## Prerequisites

Before proceeding, verify ALL of the following:

1. **Plan file exists** — the user must provide a path to a `/loopplan` output file (a markdown file with `### Unit N:` headings, a `## Shared Interfaces` section, and a `## Work Units` section)
2. **Clean git tree** — `git status --porcelain` must be empty. If dirty, ask the user to commit or stash before continuing.
3. **Git repository** — `git rev-parse --is-inside-work-tree` must succeed. If not a git repo, abort.

If any prerequisite fails, stop and tell the user what needs to be fixed.

## Setup Sequence

The setup is interactive. Every step requires either user confirmation or explicit approval. Never skip any step.

### Step 0: Run Setup Script

Run the `setup-orchestrator.sh` script from the plugin root:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup-orchestrator.sh" <PLAN_PATH> [--max-concurrent N] [--max-iterations N] [--max-retries N]
```

This script validates git hygiene, parses the plan, creates the state directory at `.claude/loop-orchestrator/`, extracts shared interfaces/decisions/acceptance tests, and creates per-unit directories with `status.json` and `context.md` files.

If the script fails, report the error to the user and stop.

After the script succeeds, proceed with the interactive setup steps below. The script intentionally does NOT start the loop — the skill handles the remaining interactive steps and then activates the Stop hook.

### Step 1: Present Decomposition for User Approval

Read `.claude/loop-orchestrator/status.json` and all unit directories under `.claude/loop-orchestrator/units/`.

Present the decomposition to the user:

- List each work unit with its name, scope, task count, and file list
- Show the recommended concurrency (min of unit count and max_concurrent from config)
- Ask the user: "N work units detected, recommended concurrency: M. How many parallel subagents? [M]:"

Wait for the user to confirm or provide a different number. Update `config.json` with the confirmed `max_concurrent` value and set `user_approved_concurrency` to `true`.

### Step 2: Present Per-Unit Definition of Done

For each work unit, draft a Definition of Done based on the unit's tasks from `context.md`. The DoD is a checklist of concrete, verifiable conditions that must be true when the unit is complete.

Write the DoD as a `## Definition of Done` section appended to each unit's `context.md` file with checkbox items. Example:

```markdown
## Definition of Done
- [ ] All API endpoints return correct status codes and response shapes
- [ ] Unit tests pass with >80% coverage of new code
- [ ] No TypeScript errors in modified files
- [ ] Shared interface contracts respected exactly
```

Present ALL unit DoDs to the user for review. The user may edit, add, or remove items. Apply any changes the user requests to the `context.md` files.

Once the user approves, set `user_approved_dod` to `true` in `config.json`.

### Step 3: Auto-Detect Test and Start Commands

Detect the project's test and start commands by checking (in order):

1. **package.json** — look for `scripts.test` and `scripts.dev` or `scripts.start`
2. **Makefile** — look for `test:` and `dev:` or `run:` targets
3. **pytest** — check for `pytest.ini`, `pyproject.toml [tool.pytest]`, or `conftest.py`
4. **cargo test** — check for `Cargo.toml`
5. **go test** — check for `go.mod`

Present the detected commands to the user:

```
Detected test command: npm test
Detected start command: npm run dev

Confirm these commands? (y/N, or provide alternatives):
```

Update `config.json` with the confirmed `test_command` and `start_command` values.

### Step 4: Create Working Branch

Read the `working_branch` value from `config.json`. Create and checkout the branch:

```bash
git checkout -b <working_branch>
```

If the branch already exists, ask the user whether to use it or pick a different name.

### Step 5: Write Loop State and Activate the Stop Hook

This is the final step. It starts the orchestrator loop by writing the `loop-state.md` file that the Stop hook reads.

1. Read the orchestrator prompt from `${CLAUDE_PLUGIN_ROOT}/skills/loopbuild/orchestrator-prompt.md`
2. Update `status.json` to set `phase` to `"executing"`
3. Write `.claude/loop-orchestrator/loop-state.md` with YAML frontmatter containing `iteration: 0` and `max_iterations` from config, followed by the full orchestrator prompt content

The `loop-state.md` file format:

```markdown
---
iteration: 0
max_iterations: 50
---

[full content of orchestrator-prompt.md]
```

Once this file exists, the Stop hook will detect it and begin feeding the orchestrator prompt back each iteration. The orchestrator loop is now active.

## Rules

- **Never skip interactive steps.** Every step (1-3) requires explicit user confirmation before proceeding.
- **Never exceed max_concurrent.** The number of parallel subagents dispatched in any single iteration must not exceed the user-approved concurrency limit.
- **Always update state.** After every action that changes status, update the relevant `status.json` file(s) immediately.
- **Escalate blocked units.** If a unit has failed `max_retries` times, mark it as `blocked` and report to the user. Do not retry blocked units without user guidance.
- **Output status every iteration.** Each orchestrator iteration must print a status summary showing the current phase, iteration number, and per-unit status.
