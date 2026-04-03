# ccHyperLoop

Parallel orchestrated development for Claude Code. Plan work into independent units, then execute them simultaneously with worktree-isolated subagents — each one building, testing, simplifying, and reviewing its own slice. When all units are done, ccHyperLoop merges everything, runs a whole-codebase review, and optionally verifies the UI with Playwright.

## How It Works

```
/loopplan                          /loopbuild <plan>
    |                                   |
    v                                   v
 Explore codebase               Git hygiene check (hard gate)
 Define shared interfaces       User approves concurrency (2-8)
 Decompose into 2-8 units       User reviews Definition of Done
 Write acceptance tests          Detect test/start commands
 Save plan                       Start orchestrator loop
                                        |
                                        v
                                 +--------------+
                                 | EXECUTING    | Dispatch subagents
                                 |  (parallel)  | in isolated worktrees
                                 +--------------+
                                        |
                                        v
                                 +--------------+
                                 | MERGING      | Merge branches,
                                 |              | run test suite
                                 +--------------+
                                        |
                                        v
                                 +--------------+
                                 | REVIEWING    | /simplify + code
                                 |              | review on full diff
                                 +--------------+
                                        |
                                        v
                                 +--------------+
                                 | VERIFYING    | Playwright acceptance
                                 | (if has UI)  | + smoke tests
                                 +--------------+
                                        |
                                        v
                                 +--------------+
                                 | DOCUMENTING  | Clean artifacts,
                                 |              | verify README
                                 +--------------+
                                        |
                                        v
                                      DONE
```

---

## Installation

### Via Claude Code Plugin Manager

```bash
claude plugin add DaveKernan/ccHyperLoop
```

### Via Git Clone

```bash
git clone https://github.com/DaveKernan/ccHyperLoop.git ~/.claude/plugins/ccHyperLoop
```

Then add the plugin path to your Claude Code settings. In `~/.claude/settings.json`, add:

```json
{
  "plugins": [
    "~/.claude/plugins/ccHyperLoop"
  ]
}
```

### Verify Installation

Start a new Claude Code session. You should see the plugin loaded. Run `/loopstatus` — it should report "No active ccHyperLoop orchestration."

---

## Quick Start

### 1. Plan

```
/loopplan
```

Describe what you want to build. The skill walks you through:

1. **Exploring your codebase** — reads project structure, tech stack, existing patterns
2. **Defining shared interfaces** — API contracts, data schemas, component props between units
3. **Decomposing into 2-8 units** — each unit owns its own files and can be built independently
4. **Writing acceptance tests** — natural-language Playwright scenarios (if your project has a UI)
5. **Self-reviewing independence** — verifies no two units touch the same files

Saves the plan to `docs/loop-plans/YYYY-MM-DD-<feature>.md` (directory created automatically if it doesn't exist).

### 2. Build

```
/loopbuild docs/loop-plans/2026-04-03-my-feature.md
```

Options:

| Flag | Default | Description |
|------|---------|-------------|
| `--max-concurrent N` | 4 | Max parallel subagents (1-8) |
| `--max-iterations N` | 50 | Max orchestrator loop iterations |
| `--max-retries N` | 3 | Retries per unit before escalating to you |

Before execution starts, you review and approve:
- **Concurrency** — how many agents run in parallel
- **Definition of Done** — per-unit checklist (edit any items you want)
- **Encouragement Mode** — optional (see below)
- **Token Optimization** — optional (see below)
- **Test and start commands** — auto-detected, you confirm

Then the orchestrator loop begins.

#### Encouragement Mode

When offered, you can enable Encouragement Mode. This appends a firm reminder to every work instruction sent to subagents:

> *"Do not be lazy, think hard, do not use placeholders without human permission, test properly and prove it works before saying done."*

This combats the tendency for agents to take shortcuts, use placeholder code, or declare "done" prematurely. It only applies to substantive work instructions, not transactional status messages. Off by default.

#### Token Optimization

When enabled, the orchestrator selects the cheapest model that can handle each work unit:

| Model | Used For | Example Units |
|-------|----------|---------------|
| **opus** | Complex multi-file architecture, integration logic, design decisions | Auth system spanning API + middleware + DB |
| **sonnet** | Standard implementation with clear scope (default for all units when disabled) | REST endpoints, React components |
| **haiku** | Simple mechanical tasks, boilerplate, config | Adding a config file, simple CRUD, copy-adapt tasks |

The orchestrator assesses each unit's `context.md` before dispatch and picks the model. When in doubt, it chooses the more capable model — a wrong pick costs more in retries than in model savings. The chosen model is logged in the status output. Off by default.

### 3. Monitor

```
/loopstatus
```

Check progress at any time:

```
ccHyperLoop Status
Phase:     EXECUTING (iteration 7/50)
Elapsed:   4m 32s
Progress:  2/4 units

Units:
  [done]        api-layer: 5/5 tasks, simplified, reviewed
  [done]        database: 3/3 tasks, simplified, reviewed
  [in_progress] ui-components: dispatched iteration 5
  [in_progress] auth-middleware: dispatched iteration 4
```

### 4. Cancel (if needed)

```
/loopcancel
```

Stops the orchestrator and cleans up worktrees. Unit branches are preserved — you can inspect or cherry-pick from them.

---

## Commands

| Command | Description |
|---------|-------------|
| `/loopplan` | Create a parallel-structured plan |
| `/loopbuild <plan> [options]` | Execute a plan with parallel agents |
| `/loopstatus` | Check orchestration progress |
| `/loopcancel` | Cancel active orchestration |
| `/loopupdate` | Update plugin from GitHub |

---

## Architecture

### Orchestrator Loop

The orchestrator runs as a [Ralph-style loop](https://ghuntley.com/ralph/) in your main Claude Code session. A Stop hook intercepts session exit and feeds the orchestrator prompt back each iteration. Each iteration, the orchestrator:

1. Reads all state files from disk
2. Makes phase-appropriate decisions (dispatch, merge, review, verify)
3. Updates state files
4. Reports status to you
5. Exits — the Stop hook catches the exit and feeds the prompt back

This continues until all phases complete or max iterations are reached.

### Subagent Isolation

Each work unit runs in its own git worktree via Claude Code's `Agent` tool with `isolation: "worktree"`. This means:

- Each subagent has a full, isolated copy of the repo
- Changes in one worktree don't affect another
- Each unit commits to its own branch (`loop/unit-01-name`, etc.)
- After completion, branches are merged back into the working branch

**Scaffold-first dispatch:** Before any subagents are dispatched, the orchestrator commits a shared scaffold to the working branch — shared types, project config, stubs for cross-unit dependencies, and test infrastructure. Worktrees clone from this branch state, so every subagent starts with a buildable project and focuses purely on its unit's scope. Without this, parallel subagents would independently create the same shared files, causing merge conflicts.

Subagents follow strict rules:
- Only modify files listed in their scope
- Respect shared interface contracts exactly
- Mock or stub dependencies from other units
- Run tests, `/simplify`, and code review before reporting done
- Commit all work to their worktree branch

### Shared State

All coordination happens through files in `.claude/loop-orchestrator/`:

```
.claude/loop-orchestrator/
  config.json              # Orchestrator settings
  status.json              # Phase, iteration, unit counts
  loop-state.md            # Ralph loop state (drives the Stop hook)
  interfaces.md            # Shared API contracts between units
  decisions.md             # Architectural decisions all units follow
  acceptance-tests.md      # Playwright scenarios from the plan
  orchestrator.log         # Debug log for hooks and scripts
  units/
    unit-01-api-layer/
      status.json          # Unit state, retries, worktree path
      context.md           # Tasks and Definition of Done
    unit-02-database/
      status.json
      context.md
    ...
```

### What Makes Units "Independent"

A work unit is independent when:
- **No file overlap** — no two units modify the same file (except shared config listed in interfaces)
- **Interface-only dependencies** — units communicate through defined contracts, not runtime coupling
- **Buildable in isolation** — each unit can compile and pass tests with only mock/stub implementations of other units

The `/loopplan` skill enforces this during planning with an independence verification checklist.

### Phases

| Phase | What Happens | Transitions To |
|-------|-------------|----------------|
| **EXECUTING** | Dispatch subagents to worktrees, monitor progress, retry failures (up to 3x per unit) | MERGING (when all units done) |
| **MERGING** | Merge unit branches into working branch, auto-resolve conflicts where possible, run full test suite | REVIEWING |
| **REVIEWING** | `/simplify` on entire merged codebase, then code review on full diff vs base branch | VERIFYING (if UI) or DOCUMENTING |
| **VERIFYING** | Playwright acceptance tests from plan + auto-generated smoke tests for uncovered routes | DOCUMENTING |
| **DOCUMENTING** | Remove artifacts, verify README is comprehensive and current, fix orphaned references, commit cleanup | DONE |
| **DONE** | Summary report — units completed, iterations used, elapsed time. Branch is ready for PR. | Exit |

### Failure Handling

| Scenario | What Happens |
|----------|-------------|
| Subagent fails | Retried up to 3 times with error context appended to the prompt |
| Retries exhausted | Unit marked `blocked`, other streams continue, you're asked for guidance |
| Merge conflict | Auto-resolve attempted. If unresolvable, escalated to you with conflict details |
| Test failure after merge | Reported with output. Orchestrator attempts fix or escalates |
| Playwright test failure | Fix-and-rerun cycle (max 3 rounds), then escalated with screenshots |
| Simplify/review unavailable | Skipped with warning — these are quality gates, not correctness gates |

---

## State Directory Reference

### config.json

```json
{
  "plan_path": "docs/loop-plans/2026-04-03-feature.md",
  "base_branch": "main",
  "working_branch": "loop/feature-name",
  "clean_start_verified": true,
  "max_concurrent": 4,
  "max_iterations": 50,
  "max_retries": 3,
  "user_approved_dod": true,
  "user_approved_concurrency": true,
  "encouragement_enabled": false,
  "token_optimization_enabled": false,
  "test_command": "npm test",
  "start_command": "npm run dev",
  "has_ui": true
}
```

### status.json

```json
{
  "phase": "executing",
  "iteration": 5,
  "max_iterations": 50,
  "plan_path": "docs/loop-plans/2026-04-03-feature.md",
  "units_total": 4,
  "units_completed": 1,
  "units_in_progress": 2,
  "units_blocked": 0,
  "units_pending": 1,
  "has_ui": true,
  "started_at": "2026-04-03T10:00:00Z"
}
```

### Per-unit status.json

```json
{
  "id": "unit-01",
  "name": "api-layer",
  "status": "in_progress",
  "worktree_path": "/tmp/claude-worktrees/project-unit-01",
  "branch": "loop/unit-01-api-layer",
  "retries": 0,
  "max_retries": 3,
  "last_error": null,
  "simplify_done": false,
  "review_done": false,
  "tasks_total": 5,
  "tasks_completed": 3
}
```

Unit status values: `pending`, `in_progress`, `done`, `blocked`, `failed`, `merge_conflict`

---

## Troubleshooting

### A unit is blocked

Run `/loopstatus` to see the error. You have three options:
- **Retry** — clear the error and let the orchestrator try again
- **Skip** — mark the unit as done (manually merge its partial work later)
- **Cancel** — run `/loopcancel` and rethink the decomposition

### Merge conflicts after EXECUTING phase

The merge script auto-resolves when possible. If it can't:
1. The conflicting unit is marked `merge_conflict` in its status.json
2. The orchestrator reports which files conflict
3. You can resolve manually on the working branch, then let the orchestrator continue

### Orchestrator seems stuck

Check the debug log:
```bash
cat .claude/loop-orchestrator/orchestrator.log
```

Check current state:
```bash
cat .claude/loop-orchestrator/status.json | jq .
```

If the loop state file is corrupted, remove it to release the Stop hook:
```bash
rm .claude/loop-orchestrator/loop-state.md
```

### Worktrees left behind after cancel

List active worktrees:
```bash
git worktree list
```

Remove stale ones:
```bash
git worktree remove /path/to/worktree --force
```

### "Not a git repository" error

`/loopbuild` requires a git repo with a clean working tree. Commit or stash your changes first.

### "An orchestrator loop is already active" error

A previous loop wasn't cleaned up. Run `/loopcancel` first, or manually:
```bash
rm -rf .claude/loop-orchestrator
```

---

## Plan Format

Plans created by `/loopplan` follow this structure:

```markdown
# Feature Name — Loop Plan

> **Execution:** Use `/loopbuild` to execute this plan.

**Goal:** Build a task management API with real-time updates
**Architecture:** REST API with WebSocket notifications, PostgreSQL backend
**Tech Stack:** Node.js, Express, Prisma, Playwright
**Has UI:** true

---

## Shared Interfaces

### API Contract: Tasks
- POST /api/tasks — { title: string, assignee: string } -> { id, title, assignee, created_at }
- GET /api/tasks — [] -> Task[]

### Data Schema: Tasks Table
- id (uuid), title (text), assignee (text), status (text), created_at (timestamp)

---

## Architectural Decisions
- Use Prisma for database access
- All API routes return { data, error } shape
- WebSocket events use { type, payload } format

---

## Work Units

### Unit 1: API Layer (estimated: 5 tasks)
**Scope:** REST endpoints for task CRUD
**Files:** src/api/tasks.ts, src/api/tasks.test.ts
**Tasks:** [step-by-step with complete code blocks...]

### Unit 2: Database Layer (estimated: 3 tasks)
**Scope:** Prisma schema and migrations
**Files:** prisma/schema.prisma, prisma/seed.ts
**Tasks:** [step-by-step with complete code blocks...]

---

## Acceptance Tests (Playwright)

### Scenario 1: Create a task
1. Navigate to /tasks
2. Click "New Task"
3. Fill in title: "Test Task", assignee: "Alice"
4. Click Submit
5. Verify: task appears in list

---

## Smoke Test Coverage
- GET / -> 200, no console errors
- GET /api/health -> 200
```

The full plan template is at `templates/plan-template.md`.

---

## Plugin Structure

```
ccHyperLoop/
  .claude-plugin/plugin.json     # Plugin metadata
  VERSION                        # Semver (0.1.0)
  CHANGELOG.md                   # Release history
  skills/
    loopplan/SKILL.md            # Planning skill
    loopbuild/
      SKILL.md                   # Orchestration skill
      orchestrator-prompt.md     # Prompt re-fed each iteration
      subagent-prompt.md         # Template for subagent dispatch
  commands/
    loopplan.md                  # /loopplan
    loopbuild.md                 # /loopbuild
    loopstatus.md                # /loopstatus
    loopcancel.md                # /loopcancel
    loopupdate.md                # /loopupdate
  hooks/
    hooks.json                   # Stop + SessionStart hooks
    orchestrator-stop-hook.sh    # Drives the orchestrator loop
    check-update.sh              # Async version check
  scripts/
    setup-orchestrator.sh        # Initialize state directory
    merge-worktrees.sh           # Merge unit branches
  templates/
    plan-template.md             # Reference plan format
```

---

## Auto-Update

ccHyperLoop checks GitHub for newer versions on every session start (async, non-blocking). If an update is available:

```
ccHyperLoop v1.1.0 available (you have v1.0.0). Run /loopupdate to update.
```

`/loopupdate` shows what changed and asks for confirmation. It refuses to run while an orchestrator loop is active.

---

## Requirements

- **Claude Code CLI** — the host environment
- **Git** — with worktree support (standard in modern git)
- **jq** — for JSON processing in hooks and scripts
- **Playwright** — installed automatically during the VERIFYING phase if needed

### Optional

- **`/simplify` skill** — used for code simplification passes (gracefully skipped if unavailable)
- **Code review skill** — used for review passes (gracefully skipped if unavailable)

---

## License

MIT
