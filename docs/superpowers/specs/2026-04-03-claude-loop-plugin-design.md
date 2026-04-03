# Claude Loop Plugin — Design Spec

> A reusable Claude Code plugin that orchestrates parallel subagent execution with worktree isolation, shared state, and Playwright verification.

**Date:** 2026-04-03  
**Status:** Approved

---

## Overview

Claude Loop is a Claude Code plugin providing two skills — `/loopplan` and `/loopbuild` — that together enable parallel, orchestrated development. A plan is decomposed into independent work units at planning time. An orchestrator Ralph loop dispatches each unit to a subagent running in an isolated git worktree. Units are simplified, reviewed, merged, and optionally verified with Playwright.

### Core Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Orchestration model | Hybrid — orchestrator is a Ralph loop, subagents are fire-and-complete in worktrees | Stop hooks are session-scoped; can't run multiple Ralph loops. Agent tool with worktree isolation gives real file separation. |
| Decomposition | Plan-driven — `/loopplan` structures independent work units | Human has best understanding of what's truly independent. |
| Distribution | Reusable plugin — works on any project | General-purpose orchestration pattern, not project-specific. |
| Failure handling | Retry 3x then escalate — blocked units pause, others continue | Keeps momentum on happy-path streams while surfacing real problems. |
| Shared state | Directory of files — structured + natural language | Clean separation of concerns, debuggable, each file has a clear purpose. |
| Playwright verification | User-defined acceptance tests + auto-generated smoke tests | Plan-defined tests for what matters, auto-generated smoke tests catch gaps. |
| Definition of Done | Orchestrator drafts, user reviews and edits before execution begins | User owns the DoD, not the orchestrator. |
| Git hygiene | Clean branch enforced as hard gate before execution | Non-negotiable starting point for clean merges. |

---

## Plugin Structure

```
claude-loop/
├── .claude-plugin/
│   └── plugin.json
├── skills/
│   ├── loopplan/
│   │   └── SKILL.md                # Planning skill
│   └── loopbuild/
│       ├── SKILL.md                # Orchestration skill
│       ├── orchestrator-prompt.md  # Re-fed each iteration
│       └── subagent-prompt.md      # Template for dispatching work units
├── commands/
│   ├── loopplan.md                 # /loopplan slash command
│   ├── loopbuild.md                # /loopbuild slash command
│   ├── loopstatus.md               # /loopstatus slash command
│   └── loopcancel.md               # /loopcancel slash command
├── hooks/
│   ├── hooks.json
│   └── orchestrator-stop-hook.sh
├── scripts/
│   ├── setup-orchestrator.sh       # Initialize state dir, validate git, start loop
│   └── merge-worktrees.sh          # Merge unit branches into working branch
└── templates/
    └── plan-template.md            # Reference template used by /loopplan skill
```

---

## State Directory (Per-Project, Created at Runtime)

```
.claude/loop-orchestrator/
├── config.json              # Orchestrator config
├── status.json              # Machine-readable overall state
├── interfaces.md            # Shared API contracts between units
├── decisions.md             # Architectural decisions
├── acceptance-tests.md      # Playwright scenarios from plan
└── units/
    ├── unit-01-name/
    │   ├── status.json      # Per-unit machine state
    │   └── context.md       # Scope, tasks, and definition of done
    └── ...
```

### Status Model

**Overall status.json:**

```json
{
  "phase": "executing",
  "iteration": 5,
  "max_iterations": 50,
  "plan_path": "docs/loop-plans/2026-04-03-feature.md",
  "units_total": 4,
  "units_completed": 1,
  "units_in_progress": 2,
  "units_blocked": 1,
  "units_pending": 0,
  "has_ui": true,
  "started_at": "2026-04-03T10:00:00Z"
}
```

**Per-unit status.json:**

```json
{
  "id": "unit-01",
  "name": "API Layer",
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

**config.json:**

```json
{
  "plan_path": "docs/loop-plans/2026-04-03-feature.md",
  "base_branch": "main",
  "working_branch": "loop/task-management-api",
  "clean_start_verified": true,
  "max_concurrent": 4,
  "max_iterations": 50,
  "max_retries": 3,
  "user_approved_dod": true,
  "user_approved_concurrency": true,
  "test_command": "npm test",
  "start_command": "npm run dev",
  "has_ui": true
}
```

The `test_command` and `start_command` are auto-detected during setup (from `package.json` scripts, `Makefile`, etc.) and confirmed with the user. These are used during the MERGING phase (full test suite) and VERIFYING phase (starting the app).

### Phase Progression

```
executing → merging → reviewing → verifying (if has_ui) → done
```

---

## `/loopplan` Skill

### Purpose

Produces plans specifically structured for parallel orchestrated execution. Aware of the orchestrator's requirements: independent work units, shared interfaces, acceptance tests.

### Differences from `/writing-plans`

| Aspect | `/writing-plans` | `/loopplan` |
|--------|------------------|-------------|
| Task structure | Sequential, numbered | Grouped into independent work units |
| Dependencies | Implicit in ordering | Explicit: interfaces.md defines contracts |
| Parallelism | Not considered | First-class — units must be independent |
| Acceptance tests | Not included | Required section with Playwright scenarios |
| UI detection | Not considered | Flags `has_ui` and requires verification |

### Plan Output Format

Saved to `docs/loop-plans/YYYY-MM-DD-<feature>.md`:

```markdown
# [Feature Name] — Loop Plan

> **Execution:** Use `/loopbuild` to execute this plan.

**Goal:** [One sentence]
**Architecture:** [2-3 sentences]
**Tech Stack:** [Key technologies]
**Has UI:** true/false

---

## Shared Interfaces

Contracts between work units. Each unit MUST respect these.

### API Contract: [Name]
- Endpoint: `POST /api/things`
- Request: `{ name: string, type: "a" | "b" }`
- Response: `{ id: string, created_at: string }`

### Data Schema: [Name]
[...]

### Component Props: [Name]
[...]

---

## Architectural Decisions

Decisions all units must follow.

- [Decision 1]
- [Decision 2]

---

## Work Units

### Unit 1: [Name] (estimated: N tasks)

**Scope:** What this unit owns
**Depends on interfaces:** [which shared interfaces it implements/consumes]
**Files:**
- Create: `src/api/things.ts`
- Create: `src/api/things.test.ts`

**Tasks:**
- [ ] Step 1: [with full code blocks, exact file paths, no placeholders]
- [ ] Step 2: [...]

### Unit 2: [Name]
[same structure]

---

## Acceptance Tests (Playwright)

### Scenario 1: [User flow name]
1. Navigate to /things
2. Click "Create New"
3. Fill in name: "Test Thing"
4. Click Submit
5. Verify: redirected to /things/[id]

### Scenario 2: [...]

---

## Smoke Test Coverage

Pages/routes that should load without errors:
- GET / → 200, no console errors
- GET /api/health → 200
```

### Process

1. Explore codebase — understand existing structure, patterns, tech stack
2. Analyze user request — what are they building?
3. Identify natural decomposition — what can be worked on independently?
4. Define interfaces first — contracts between units designed before units themselves
5. Structure work units — full task detail, complete code blocks, exact file paths, no placeholders
6. Write acceptance tests — Playwright scenarios for user-facing verification
7. Flag UI presence — `has_ui: true/false`
8. Self-review — verify units are truly independent (no unit modifies another's files), interfaces complete
9. Save plan and get user approval

### Independence Verification

Before finalizing, `/loopplan` must verify:
- No two units modify the same file (except shared config listed in interfaces)
- Each unit can be built and tested in isolation with only the interface contracts
- No unit depends on another unit's output to start

If true independence isn't possible, mark dependencies explicitly. The orchestrator will sequence those units rather than parallelize them.

---

## `/loopbuild` Skill

### Invocation

```
/loopbuild docs/loop-plans/2026-04-03-my-feature.md --max-concurrent 4 --max-iterations 50
```

**Arguments:**
- `PLAN_PATH` (required) — path to `/loopplan` output
- `--max-concurrent N` — max parallel subagents per iteration (default: 4, max: 8)
- `--max-iterations N` — max orchestrator iterations (default: 50)
- `--max-retries N` — retries per unit before blocking (default: 3)

### Setup Sequence

```
Step 0:  GIT HYGIENE CHECK (HARD GATE)
         ├── Is this a git repo? → No: ABORT
         ├── Is working tree clean? → Dirty: ABORT
         ├── On main/master? → Create loop/<feature> branch
         └── Record base_branch in config.json

Step 1:  Parse plan — extract units, interfaces, decisions, acceptance tests, has_ui
Step 2:  Validate plan format
Step 2a: USER APPROVES CONCURRENCY
         "4 work units, recommended concurrency: 4. How many? [4]:"
Step 2b: USER REVIEWS PER-UNIT DEFINITION OF DONE
         Orchestrator drafts DoD per unit from plan tasks.
         User reviews, edits if needed. Stored in each unit's context.md.
Step 3:  Create state directory with all files
Step 4:  Create working branch (if not already done)
Step 5:  Auto-detect test_command and start_command, confirm with user
Step 6:  Start orchestrator Ralph loop
         └── setup-orchestrator.sh writes .claude/loop-orchestrator/loop-state.md
             (YAML frontmatter with iteration count + orchestrator-prompt.md content)
             The Stop hook reads this file to drive the loop.
```

### Orchestrator Loop (Per Iteration)

The Stop hook feeds `orchestrator-prompt.md` back each iteration. The orchestrator:

1. Reads `status.json` and all unit status files
2. Based on current phase, executes:

**Phase: EXECUTING**
- Pending units + room for more? → Dispatch subagents (Agent tool, `isolation: "worktree"`)
- Subagents returned? → Read results, update unit status
- Failed, retries < 3? → Re-dispatch with error context
- Blocked, retries >= 3? → Report to user, pause that unit
- All units done? → Transition to MERGING

**Phase: MERGING**
- Merge each unit branch into working branch
- Attempt auto-resolve conflicts, escalate if can't
- Run full test suite after all merges
- All clean? → Transition to REVIEWING

**Phase: REVIEWING**
- Run `/simplify` on entire merged codebase
- Run review skill on full diff (working branch vs base)
- Issues found? → Fix, re-review (max 2 rounds)
- Clean? → Transition to VERIFYING (if `has_ui`) or DONE

**Phase: VERIFYING**
- Write Playwright test files from `acceptance-tests.md`
- Auto-generate smoke tests for uncovered routes
- Start app in background
- Run all Playwright tests
- All pass? → Transition to DONE
- Failures? → Fix, re-run (max 3 rounds), escalate if stuck

**Phase: DONE**
- Output `<promise>LOOP COMPLETE</promise>`
- Print summary: units completed, iterations used, time elapsed

### Subagent Lifecycle

```
PENDING → dispatched → IN_PROGRESS → success → DONE
                                    → failure → retry (up to 3) → BLOCKED
```

Each subagent:
1. Works through tasks in its `context.md`
2. Runs tests after each task
3. Invokes `/simplify` on own changes
4. Runs code-reviewer agent on own changes
5. Verifies every item in its Definition of Done
6. Commits to worktree branch
7. Returns result to orchestrator

### Subagent Prompt Template

Rendered per-unit with:
- Unit name and scope
- Shared interfaces (from `interfaces.md`)
- Architectural decisions (from `decisions.md`)
- Unit tasks and Definition of Done (from `context.md`)
- Retry context if applicable (previous errors)

Rules enforced:
- ONLY modify files listed in unit scope
- Respect shared interfaces exactly
- If blocked on something outside scope, report what's needed

### Stop Hook

`orchestrator-stop-hook.sh`:
1. Check `.claude/loop-orchestrator/config.json` exists (loop active)
2. Read `status.json` — if phase is `done`, allow exit
3. Check iteration vs max_iterations
4. If not done and under max: block exit, feed `orchestrator-prompt.md`, increment iteration
5. If over max: allow exit, report timeout

### User Visibility

Each iteration outputs status:

```
🔄 Loop iteration 5 | Phase: EXECUTING | 2/4 units done, 2 in progress
  ✅ unit-01-api-layer: DONE (3 tasks, simplified, reviewed)
  ✅ unit-02-database: DONE (2 tasks, simplified, reviewed)
  🔧 unit-03-ui-components: IN_PROGRESS (dispatched iteration 4)
  🔧 unit-04-auth-middleware: IN_PROGRESS (dispatched iteration 3)
```

---

## Playwright Verification (Phase: VERIFYING)

Only runs when `has_ui: true`.

### Part 1: Acceptance Tests

Generated from natural-language scenarios in `acceptance-tests.md`:

```typescript
import { test, expect } from '@playwright/test';

test('User can create a new thing', async ({ page }) => {
  await page.goto('/things');
  await page.click('text=Create New');
  await page.fill('[name="name"]', 'Test Thing');
  await page.click('text=Submit');
  await expect(page).toHaveURL(/\/things\/[\w-]+/);
  await expect(page.locator('h1')).toContainText('Test Thing');
});
```

### Part 2: Auto-Generated Smoke Tests

For routes/pages not covered by acceptance tests:

1. Detect framework (Next.js, Remix, Express, etc.)
2. Enumerate routes from file-based routing or route definitions
3. Diff against acceptance test coverage
4. Generate smoke tests: navigate, check 200, check no console errors

### Execution Flow

1. Ensure app can start (detect start command, launch, wait for ready)
2. Install Playwright if needed (`npx playwright install --with-deps chromium`)
3. Generate test files (acceptance + smoke)
4. Run all Playwright tests
5. All pass? → DONE
6. Failures? → Analyze (test issue or code issue?), fix, re-run (max 3 rounds)
7. Still failing? → Escalate to user with failure details and screenshots

### No UI Path

When `has_ui: false`:
```
EXECUTING → MERGING → REVIEWING → DONE
```
Full test suite runs during MERGING but no Playwright.

---

## Supporting Commands

### `/loopstatus`

Check progress of active orchestration at any time. Reads state directory and reports:
- Current phase and iteration
- Per-unit status summary
- Blocked units and their errors
- Time elapsed

### `/loopcancel`

Cancel active orchestration:
- Remove state directory
- Clean up worktrees
- Report cancellation with iteration count

---

## Plugin Dependencies

**None.** Claude Loop is self-contained. It uses:
- Claude Code Agent tool with `isolation: "worktree"` (built-in)
- Claude Code Stop hook API (built-in)
- Git worktrees (git built-in)
- Playwright (installed at verification time if needed)
- `/simplify` and code-review skills are invoked if available. If not installed, the subagent skips those DoD items and the orchestrator logs a warning. The unit is still considered done — simplify and review are quality gates, not correctness gates. The REVIEWING phase (whole-codebase review) also gracefully skips if unavailable.

---

## Out of Scope

- MCP-based state communication (files on disk are sufficient)
- Formal agent definitions (orchestrator skill defines behavior)
- Auto-detection of UI (user/plan declares `has_ui`)
- Cross-repo orchestration (single repo only)
