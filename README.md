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
                                      DONE
```

## Installation

```bash
claude plugin add DaveKernan/ccHyperLoop
```

Or clone directly:

```bash
git clone https://github.com/DaveKernan/ccHyperLoop.git
```

Then add the plugin path in your Claude Code settings.

## Quick Start

### 1. Plan

```
/loopplan
```

Describe what you want to build. The skill walks you through:
- Exploring your codebase
- Defining shared interfaces between work units
- Decomposing into 2-8 independent units
- Writing Playwright acceptance tests (if UI)

Outputs a plan to `docs/loop-plans/YYYY-MM-DD-<feature>.md`.

### 2. Build

```
/loopbuild docs/loop-plans/2026-04-03-my-feature.md
```

Options:
- `--max-concurrent N` — max parallel subagents (default: 4, max: 8)
- `--max-iterations N` — max orchestrator loop iterations (default: 50)
- `--max-retries N` — retries per unit before escalating (default: 3)

Before execution starts, you'll review and approve:
- Number of concurrent agents
- Per-unit Definition of Done
- Test and start commands

### 3. Monitor

```
/loopstatus
```

Check progress at any time — phase, iteration, per-unit status, blocked units.

### 4. Cancel (if needed)

```
/loopcancel
```

Stops the orchestrator, cleans up worktrees. Unit branches are preserved for inspection.

## Commands

| Command | Description |
|---------|-------------|
| `/loopplan` | Create a parallel-structured plan |
| `/loopbuild <plan>` | Execute a plan with parallel agents |
| `/loopstatus` | Check orchestration progress |
| `/loopcancel` | Cancel active orchestration |
| `/loopupdate` | Update plugin from GitHub |

## Architecture

### Orchestrator Loop

The orchestrator runs as a Ralph-style loop in your main session. A Stop hook intercepts exit and feeds the orchestrator prompt back each iteration. The orchestrator reads state from disk, dispatches subagents, and advances through phases.

### Subagent Isolation

Each work unit runs in its own git worktree via the Agent tool's `isolation: "worktree"` parameter. Subagents:
- Only modify files in their assigned scope
- Follow shared interface contracts exactly
- Run tests, `/simplify`, and code review before reporting done
- Commit all work to their worktree branch

### Shared State

All coordination happens through files in `.claude/loop-orchestrator/`:

```
.claude/loop-orchestrator/
  config.json            # Orchestrator settings
  status.json            # Phase, iteration, unit counts
  interfaces.md          # Shared API contracts
  decisions.md           # Architectural decisions
  acceptance-tests.md    # Playwright scenarios
  units/
    unit-01-name/
      status.json        # Unit state (pending/in_progress/done/blocked)
      context.md         # Tasks and Definition of Done
```

### Failure Handling

- Units retry up to 3 times with error context appended
- Blocked units pause while other streams continue
- Merge conflicts are auto-resolved when possible, escalated when not
- Playwright failures trigger fix-and-rerun cycles (max 3 rounds)

### Phases

| Phase | What Happens |
|-------|-------------|
| **EXECUTING** | Dispatch subagents to worktrees, monitor progress, retry failures |
| **MERGING** | Merge unit branches into working branch, run full test suite |
| **REVIEWING** | `/simplify` + code review on entire merged codebase |
| **VERIFYING** | Playwright acceptance tests + auto-generated smoke tests (UI only) |
| **DONE** | Summary report, ready for PR |

## Auto-Update

ccHyperLoop checks GitHub for newer versions on every session start (async, non-blocking). If an update is available:

```
ccHyperLoop v1.1.0 available (you have v1.0.0). Run /loopupdate to update.
```

`/loopupdate` refuses to run while an orchestrator loop is active.

## Requirements

- Claude Code CLI
- Git (with worktree support)
- `jq` (for JSON processing in hooks/scripts)
- Playwright (installed automatically during verification if needed)

## Optional Dependencies

- `/simplify` skill — used for code simplification passes (skipped if unavailable)
- Code review skill — used for review passes (skipped if unavailable)

## License

MIT
