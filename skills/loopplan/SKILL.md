---
name: loopplan
description: Create parallel-structured plans for orchestrated execution with /loopbuild. Use when the user wants to plan work for parallel subagent execution, mentions "loop plan", "parallel plan", or wants to structure work into independent units.
---

# loopplan

> "I'm using the loopplan skill to create a parallel-structured implementation plan."

Announce this at the start of every invocation.

## How This Differs from Regular Plans

Regular sequential plans list numbered steps that execute in order. Loop plans are fundamentally different:

- **Independent work units** — Each unit is a self-contained block of work that can be built in isolation by a separate subagent in its own git worktree. Units never touch each other's files.
- **Shared interfaces** — Before defining any unit, define the contracts between them (API endpoints, data schemas, component props, shared types). Every unit builds against these contracts, not against another unit's implementation.
- **Acceptance tests** — Natural-language Playwright scenarios that verify the integrated result after all units are merged. These are written at plan time, not after implementation.
- **UI detection** — The plan explicitly flags whether the feature includes a user interface (`Has UI: true/false`). This determines whether the orchestrator runs Playwright verification after merging.

## Process (9 Steps)

### Step 1: Explore the Codebase

Read the project structure, existing patterns, tech stack, testing setup, and conventions. Understand what already exists before proposing anything new.

### Step 2: Understand the Request

Clarify what the user is building. Ask questions if the scope is ambiguous. Identify the desired outcome, not just the implementation.

### Step 3: Define Interfaces FIRST

Before identifying work units, design the contracts that connect them:

- **API contracts** — Endpoint paths, HTTP methods, request/response shapes
- **Data schemas** — Database tables, TypeScript types, validation rules
- **Component props** — React/Vue/Svelte component interfaces
- **Shared types** — Enums, constants, utility types used across units

Interfaces are the backbone of parallel work. If interfaces are wrong, every unit is wrong.

### Step 3a: Identify Shared Scaffold

Determine what must exist on the working branch *before* any subagent is dispatched. The orchestrator commits this scaffold so every worktree starts with a buildable project. Include in the plan's Shared Interfaces section:

- **Shared type definition files** — types/interfaces referenced by multiple units
- **Project config** — `tsconfig.json`, `package.json` with shared dependencies, database config
- **Stub files** — if Unit A consumes an API that Unit B implements, define the stub that Unit A builds against
- **Test infrastructure** — shared test config, fixtures, utilities used by multiple units

These are NOT part of any unit's tasks — the orchestrator creates them from the interfaces section before dispatch. Each unit's tasks should assume the scaffold already exists.

### Step 4: Identify Independent Work Units (2-8)

Decompose the feature into 2-8 work units. Each unit:

- Owns its files exclusively — no two units modify the same file
- Can be built and tested in isolation using only the shared interfaces
- Does not depend on another unit's output to start work
- Has a clear scope boundary

### Step 5: Structure Each Unit

For every work unit, specify:

- **Scope** — What this unit owns and is responsible for
- **Interfaces** — Which shared interfaces it implements or consumes
- **Files** — Exact file paths to create or modify (no overlaps between units)
- **Tasks** — Step-by-step implementation with full code blocks, exact file paths, and no placeholders. Every task must contain enough detail that a subagent can execute it without asking questions.

### Step 6: Write Acceptance Tests

Write natural-language Playwright scenarios that verify the feature works end-to-end after all units are merged. These describe user-facing behavior:

```
### Scenario: User creates a new item
1. Navigate to /items
2. Click "Create New"
3. Fill in name: "Test Item"
4. Click Submit
5. Verify: redirected to /items/[id]
6. Verify: page shows "Test Item" in the heading
```

### Step 7: Write Smoke Test Coverage

List routes and pages that should load without errors after merge. These catch regressions beyond the acceptance test scenarios:

```
- GET / → 200, no console errors
- GET /api/health → 200
- GET /items → 200, no console errors
```

### Step 8: Self-Review Independence Verification

Before saving, verify the plan passes this checklist:

- [ ] No two units modify the same file (except shared config explicitly listed in interfaces)
- [ ] Each unit can be built and tested in isolation with only the interface contracts
- [ ] No unit depends on another unit's output to start
- [ ] Every task has full code blocks — no placeholders like "implement the logic here"
- [ ] Shared interfaces are complete — no implicit contracts between units
- [ ] Acceptance tests cover the primary user flows
- [ ] Smoke tests cover all routes/pages
- [ ] Unit count is between 2 and 8

If any check fails, restructure the plan before proceeding.

### Step 9: Save the Plan

Save to `docs/loop-plans/YYYY-MM-DD-<feature>.md` using the template at `${CLAUDE_PLUGIN_ROOT}/templates/plan-template.md`.

Create the `docs/loop-plans/` directory if it does not exist.

## Key Rules

1. **Interfaces before units** — Always define shared contracts before decomposing into work units. Never the reverse.
2. **No file overlap** — If two units need to modify the same file, restructure until they don't, or merge those units.
3. **No placeholders** — Every task must have complete, copy-pasteable code blocks. A subagent executing the plan should never need to invent implementation details.
4. **Flag UI explicitly** — Set `Has UI: true` if the feature includes any user-facing pages or components. This triggers Playwright verification in `/loopbuild`.
5. **2-8 units** — Fewer than 2 means the work isn't parallelizable. More than 8 means units are too granular and coordination overhead dominates.
6. **Dependencies must be explicit** — If true independence between units is not achievable, mark the dependency explicitly with a `Depends on:` field. The orchestrator will sequence dependent units rather than parallelize them.

## Plan Output Format

The saved plan must follow this structure:

```markdown
# [Feature Name] — Loop Plan

> **Execution:** Use `/loopbuild` to execute this plan.

**Goal:** [One sentence]
**Architecture:** [2-3 sentences]
**Tech Stack:** [Key technologies]
**Has UI:** true/false

---

## Shared Interfaces

[API contracts, data schemas, component props, shared types]

---

## Architectural Decisions

[Decisions all units must follow]

---

## Work Units

### Unit 1: [Name] (estimated: N tasks)

**Scope:** [...]
**Depends on interfaces:** [...]
**Files:**
- Create: `path/to/file`

**Tasks:**
- [ ] Step 1: [full detail with code blocks]

### Unit 2: [Name] (estimated: N tasks)
[same structure]

---

## Acceptance Tests (Playwright)

### Scenario 1: [name]
[numbered steps]

---

## Smoke Test Coverage

[routes that should load without errors]
```

See `${CLAUDE_PLUGIN_ROOT}/templates/plan-template.md` for the complete reference template.
