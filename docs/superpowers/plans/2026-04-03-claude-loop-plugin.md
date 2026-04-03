# Claude Loop Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Tasks 2-7 are independent and can be dispatched in parallel after Task 1 completes.

**Goal:** Build a reusable Claude Code plugin that orchestrates parallel subagent execution with worktree isolation, shared state, and Playwright verification.

**Architecture:** Plugin with 2 skills (`/loopplan`, `/loopbuild`), 5 commands, a Stop hook for the orchestrator Ralph loop, an async SessionStart hook for version checking, 2 shell scripts for setup/merge, and prompt templates for orchestrator and subagent dispatch. All state lives in `.claude/loop-orchestrator/` at runtime.

**Tech Stack:** Bash (shell scripts/hooks), Markdown with YAML frontmatter (skills/commands/prompts), JSON (state files), `jq` (JSON manipulation), `git` (worktrees/branching), `gh` CLI (version check)

**Spec:** `docs/superpowers/specs/2026-04-03-claude-loop-plugin-design.md`

---

## File Structure

All paths are relative to the plugin root: `/Users/davidkernan/projects/claudeLoop/`

**Create:**
- `.claude-plugin/plugin.json` — Plugin metadata with name, version, repository
- `VERSION` — Semver string (`0.1.0`)
- `CHANGELOG.md` — Release history
- `hooks/hooks.json` — Hook configuration (SessionStart + Stop)
- `hooks/orchestrator-stop-hook.sh` — Stop hook that drives the orchestrator Ralph loop
- `hooks/check-update.sh` — Async version check against GitHub
- `scripts/setup-orchestrator.sh` — Initializes state directory, validates git, starts loop
- `scripts/merge-worktrees.sh` — Merges unit branches into working branch
- `skills/loopplan/SKILL.md` — Planning skill for parallel-structured plans
- `skills/loopbuild/SKILL.md` — Orchestration skill that runs the loop
- `skills/loopbuild/orchestrator-prompt.md` — Prompt fed back each iteration
- `skills/loopbuild/subagent-prompt.md` — Template for dispatching work units
- `commands/loopplan.md` — `/loopplan` slash command
- `commands/loopbuild.md` — `/loopbuild` slash command
- `commands/loopstatus.md` — `/loopstatus` slash command
- `commands/loopcancel.md` — `/loopcancel` slash command
- `commands/loopupdate.md` — `/loopupdate` slash command
- `templates/plan-template.md` — Reference template for plan format

---

### Task 1: Plugin Scaffold

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `VERSION`
- Create: `CHANGELOG.md`

This task must complete before all others — it establishes the plugin identity.

- [ ] **Step 1: Create plugin directory structure**

```bash
mkdir -p .claude-plugin hooks scripts skills/loopplan skills/loopbuild commands templates
```

- [ ] **Step 2: Write plugin.json**

Create `.claude-plugin/plugin.json`:

```json
{
  "name": "claude-loop",
  "version": "0.1.0",
  "description": "Parallel orchestrated development with worktree-isolated subagents, shared state, and Playwright verification. Use /loopplan to plan and /loopbuild to execute.",
  "author": {
    "name": "David Kernan"
  },
  "repository": "https://github.com/davidkernan/claude-loop",
  "license": "MIT",
  "keywords": [
    "orchestration",
    "parallel",
    "worktree",
    "loop",
    "subagent",
    "playwright"
  ]
}
```

- [ ] **Step 3: Write VERSION file**

Create `VERSION`:

```
0.1.0
```

- [ ] **Step 4: Write CHANGELOG**

Create `CHANGELOG.md`:

```markdown
# Changelog

## 0.1.0 — 2026-04-03

Initial release.

- `/loopplan` skill for parallel-structured planning
- `/loopbuild` skill for orchestrated parallel execution
- Orchestrator Ralph loop with Stop hook
- Git worktree isolation per work unit
- Shared state directory (`.claude/loop-orchestrator/`)
- Subagent dispatch with retry (3x) and escalation
- Per-unit simplify and review gates
- Whole-codebase simplify and review after merge
- Playwright acceptance + smoke test verification
- Async version check on session start
- `/loopstatus`, `/loopcancel`, `/loopupdate` commands
```

- [ ] **Step 5: Commit scaffold**

```bash
git add .claude-plugin/plugin.json VERSION CHANGELOG.md
git commit -m "feat: initialize claude-loop plugin scaffold"
```

---

### Task 2: Stop Hook (orchestrator-stop-hook.sh)

**Files:**
- Create: `hooks/orchestrator-stop-hook.sh`

This is the engine of the orchestrator loop. It intercepts session exit and feeds the orchestrator prompt back.

- [ ] **Step 1: Write orchestrator-stop-hook.sh**

Create `hooks/orchestrator-stop-hook.sh`:

```bash
#!/bin/bash

# Claude Loop Orchestrator Stop Hook
# Prevents session exit when an orchestrator loop is active.
# Reads loop state, checks completion, and feeds the orchestrator prompt back.

set -euo pipefail

HOOK_INPUT=$(cat)

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")

CONFIG_FILE="${PROJECT_ROOT}/.claude/loop-orchestrator/config.json"
STATUS_FILE="${PROJECT_ROOT}/.claude/loop-orchestrator/status.json"
LOOP_STATE_FILE="${PROJECT_ROOT}/.claude/loop-orchestrator/loop-state.md"
LOG_FILE="${PROJECT_ROOT}/.claude/loop-orchestrator/orchestrator.log"

# No active loop — allow exit
if [[ ! -f "$CONFIG_FILE" ]]; then
  exit 0
fi

# No loop state file — allow exit (loop not started yet or already cleaned up)
if [[ ! -f "$LOOP_STATE_FILE" ]]; then
  exit 0
fi

log_error() {
  local msg="$1"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $msg" >> "$LOG_FILE" 2>/dev/null || true
  echo "WARNING: Claude Loop orchestrator: $msg" >&2
}

# Parse loop state frontmatter
FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$LOOP_STATE_FILE")
ITERATION=$(echo "$FRONTMATTER" | grep '^iteration:' | sed 's/iteration: *//')
MAX_ITERATIONS=$(echo "$FRONTMATTER" | grep '^max_iterations:' | sed 's/max_iterations: *//')

# Validate numeric fields
if [[ ! "$ITERATION" =~ ^[0-9]+$ ]]; then
  log_error "Loop state corrupted: iteration='$ITERATION'"
  rm -f "$LOOP_STATE_FILE"
  exit 0
fi

if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  log_error "Loop state corrupted: max_iterations='$MAX_ITERATIONS'"
  rm -f "$LOOP_STATE_FILE"
  exit 0
fi

# Check if phase is done — allow exit
if [[ -f "$STATUS_FILE" ]]; then
  PHASE=$(jq -r '.phase // "unknown"' "$STATUS_FILE" 2>/dev/null || echo "unknown")
  if [[ "$PHASE" == "done" ]]; then
    rm -f "$LOOP_STATE_FILE"
    exit 0
  fi
fi

# Check max iterations
if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $ITERATION -ge $MAX_ITERATIONS ]]; then
  echo "Claude Loop: Max iterations ($MAX_ITERATIONS) reached. Stopping orchestrator."
  rm -f "$LOOP_STATE_FILE"
  exit 0
fi

# Check for completion promise in last assistant output
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path' 2>/dev/null || echo "")

if [[ -n "$TRANSCRIPT_PATH" ]] && [[ -f "$TRANSCRIPT_PATH" ]]; then
  LAST_OUTPUT=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" | tail -1 | jq -r '
    .message.content |
    map(select(.type == "text")) |
    map(.text) |
    join("\n")
  ' 2>/dev/null || echo "")

  if echo "$LAST_OUTPUT" | grep -q '<promise>LOOP COMPLETE</promise>'; then
    echo "Claude Loop: Orchestration complete."
    rm -f "$LOOP_STATE_FILE"
    exit 0
  fi
fi

# Not done — continue loop
NEXT_ITERATION=$((ITERATION + 1))

# Extract the orchestrator prompt (everything after closing ---)
PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$LOOP_STATE_FILE")

if [[ -z "$PROMPT_TEXT" ]]; then
  log_error "No prompt text in loop state file"
  rm -f "$LOOP_STATE_FILE"
  exit 0
fi

# Update iteration in state file
TEMP_FILE="${LOOP_STATE_FILE}.tmp.$$"
sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$LOOP_STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$LOOP_STATE_FILE"

# Build status summary for system message
UNITS_SUMMARY=""
if [[ -f "$STATUS_FILE" ]]; then
  UNITS_COMPLETED=$(jq -r '.units_completed // 0' "$STATUS_FILE" 2>/dev/null || echo "0")
  UNITS_TOTAL=$(jq -r '.units_total // 0' "$STATUS_FILE" 2>/dev/null || echo "0")
  UNITS_BLOCKED=$(jq -r '.units_blocked // 0' "$STATUS_FILE" 2>/dev/null || echo "0")
  PHASE=$(jq -r '.phase // "executing"' "$STATUS_FILE" 2>/dev/null || echo "executing")
  UNITS_SUMMARY=" | Phase: ${PHASE} | ${UNITS_COMPLETED}/${UNITS_TOTAL} units done"
  if [[ "$UNITS_BLOCKED" -gt 0 ]]; then
    UNITS_SUMMARY="${UNITS_SUMMARY}, ${UNITS_BLOCKED} blocked"
  fi
fi

SYSTEM_MSG="Claude Loop iteration ${NEXT_ITERATION}${UNITS_SUMMARY} | To complete: output <promise>LOOP COMPLETE</promise>"

jq -n \
  --arg prompt "$PROMPT_TEXT" \
  --arg msg "$SYSTEM_MSG" \
  '{
    "decision": "block",
    "reason": $prompt,
    "systemMessage": $msg
  }'

exit 0
```

- [ ] **Step 2: Make executable**

```bash
chmod +x hooks/orchestrator-stop-hook.sh
```

- [ ] **Step 3: Test the hook with no active loop (should allow exit)**

```bash
echo '{}' | ./hooks/orchestrator-stop-hook.sh
echo "Exit code: $?"
```

Expected: exit code 0, no output (allows exit).

- [ ] **Step 4: Commit**

```bash
git add hooks/orchestrator-stop-hook.sh
git commit -m "feat: add orchestrator stop hook for Ralph loop"
```

---

### Task 3: Session Start Hook & hooks.json

**Files:**
- Create: `hooks/check-update.sh`
- Create: `hooks/hooks.json`

- [ ] **Step 1: Write check-update.sh**

Create `hooks/check-update.sh`:

```bash
#!/bin/bash

# Claude Loop — Async version check on session start
# Compares local VERSION against latest GitHub release.
# Silently exits on any failure (network, missing tools, etc.)

set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$0")")}"
VERSION_FILE="${PLUGIN_ROOT}/VERSION"

# Read local version
if [[ ! -f "$VERSION_FILE" ]]; then
  exit 0
fi
LOCAL_VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')

if [[ -z "$LOCAL_VERSION" ]]; then
  exit 0
fi

# Read repo URL from plugin.json
PLUGIN_JSON="${PLUGIN_ROOT}/.claude-plugin/plugin.json"
if [[ ! -f "$PLUGIN_JSON" ]]; then
  exit 0
fi

REPO_URL=$(jq -r '.repository // ""' "$PLUGIN_JSON" 2>/dev/null || echo "")
if [[ -z "$REPO_URL" ]]; then
  exit 0
fi

# Extract owner/repo from URL (handles https://github.com/owner/repo)
OWNER_REPO=$(echo "$REPO_URL" | sed -n 's|.*github\.com/\([^/]*/[^/]*\).*|\1|p' | sed 's/\.git$//')
if [[ -z "$OWNER_REPO" ]]; then
  exit 0
fi

# Fetch latest release tag — try gh first, fall back to curl
REMOTE_TAG=""
if command -v gh &>/dev/null; then
  REMOTE_TAG=$(gh api "repos/${OWNER_REPO}/releases/latest" --jq '.tag_name' 2>/dev/null || echo "")
fi

if [[ -z "$REMOTE_TAG" ]]; then
  REMOTE_TAG=$(curl -sf --max-time 5 \
    "https://api.github.com/repos/${OWNER_REPO}/releases/latest" 2>/dev/null \
    | jq -r '.tag_name // ""' 2>/dev/null || echo "")
fi

if [[ -z "$REMOTE_TAG" ]]; then
  exit 0
fi

# Strip leading 'v' from tag
REMOTE_VERSION="${REMOTE_TAG#v}"

# Compare versions (simple string comparison — works for semver with same digit counts)
if [[ "$REMOTE_VERSION" != "$LOCAL_VERSION" ]]; then
  # Use sort -V for proper semver comparison
  HIGHER=$(printf '%s\n%s' "$LOCAL_VERSION" "$REMOTE_VERSION" | sort -V | tail -1)
  if [[ "$HIGHER" == "$REMOTE_VERSION" ]] && [[ "$HIGHER" != "$LOCAL_VERSION" ]]; then
    echo "{\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":\"Claude Loop v${REMOTE_VERSION} available (you have v${LOCAL_VERSION}). Run /loopupdate to update.\"}}"
  fi
fi

exit 0
```

- [ ] **Step 2: Make executable**

```bash
chmod +x hooks/check-update.sh
```

- [ ] **Step 3: Write hooks.json**

Create `hooks/hooks.json`:

```json
{
  "description": "Claude Loop plugin hooks — orchestrator Stop hook and async version check",
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/check-update.sh",
            "async": true
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/orchestrator-stop-hook.sh"
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 4: Commit**

```bash
git add hooks/check-update.sh hooks/hooks.json
git commit -m "feat: add hooks.json with stop hook and async version check"
```

---

### Task 4: Setup Orchestrator Script

**Files:**
- Create: `scripts/setup-orchestrator.sh`

This is the most complex script — it parses the plan, validates git state, creates the state directory, and starts the loop.

- [ ] **Step 1: Write setup-orchestrator.sh**

Create `scripts/setup-orchestrator.sh`:

```bash
#!/bin/bash

# Claude Loop — Setup Orchestrator
# Validates git hygiene, parses the plan, creates state directory,
# and writes the loop state file to start the orchestrator Ralph loop.

set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$0")")}"

# ─── Argument Parsing ───

PLAN_PATH=""
MAX_CONCURRENT=4
MAX_ITERATIONS=50
MAX_RETRIES=3

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      cat << 'HELP'
Claude Loop Orchestrator Setup

USAGE:
  /loopbuild <PLAN_PATH> [OPTIONS]

ARGUMENTS:
  PLAN_PATH    Path to a /loopplan output file (required)

OPTIONS:
  --max-concurrent <n>    Max parallel subagents (default: 4, max: 8)
  --max-iterations <n>    Max orchestrator iterations (default: 50)
  --max-retries <n>       Retries per unit before blocking (default: 3)
  -h, --help              Show this help

EXAMPLES:
  /loopbuild docs/loop-plans/2026-04-03-feature.md
  /loopbuild docs/loop-plans/2026-04-03-feature.md --max-concurrent 6 --max-iterations 30
HELP
      exit 0
      ;;
    --max-concurrent)
      if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "ERROR: --max-concurrent requires a number (1-8)" >&2; exit 1
      fi
      MAX_CONCURRENT="$2"
      if [[ $MAX_CONCURRENT -lt 1 ]] || [[ $MAX_CONCURRENT -gt 8 ]]; then
        echo "ERROR: --max-concurrent must be between 1 and 8" >&2; exit 1
      fi
      shift 2
      ;;
    --max-iterations)
      if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "ERROR: --max-iterations requires a positive number" >&2; exit 1
      fi
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    --max-retries)
      if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "ERROR: --max-retries requires a positive number" >&2; exit 1
      fi
      MAX_RETRIES="$2"
      shift 2
      ;;
    *)
      if [[ -z "$PLAN_PATH" ]]; then
        PLAN_PATH="$1"
      else
        echo "ERROR: Unexpected argument: $1" >&2; exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$PLAN_PATH" ]]; then
  echo "ERROR: No plan path provided." >&2
  echo "Usage: /loopbuild <PLAN_PATH> [OPTIONS]" >&2
  echo "Run /loopbuild --help for details." >&2
  exit 1
fi

if [[ ! -f "$PLAN_PATH" ]]; then
  echo "ERROR: Plan file not found: $PLAN_PATH" >&2
  exit 1
fi

# ─── Git Hygiene Check (Hard Gate) ───

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  echo "ERROR: Not a git repository. /loopbuild requires git." >&2
  exit 1
fi

PROJECT_ROOT=$(git rev-parse --show-toplevel)

if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  echo "ERROR: Working tree has uncommitted changes." >&2
  echo "Commit or stash before running /loopbuild." >&2
  exit 1
fi

CURRENT_BRANCH=$(git branch --show-current)
BASE_BRANCH="$CURRENT_BRANCH"

# Check if already an active loop
if [[ -f "${PROJECT_ROOT}/.claude/loop-orchestrator/config.json" ]]; then
  echo "ERROR: An orchestrator loop is already active." >&2
  echo "Run /loopcancel first, or wait for it to complete." >&2
  exit 1
fi

# ─── Parse Plan Metadata ───

# Extract Has UI flag
HAS_UI="false"
if grep -qi '^[*]*Has UI[*]*:.*true' "$PLAN_PATH"; then
  HAS_UI="true"
fi

# Count work units (lines matching "### Unit N:")
UNIT_COUNT=$(grep -c '^### Unit [0-9]' "$PLAN_PATH" || echo "0")

if [[ "$UNIT_COUNT" -eq 0 ]]; then
  echo "ERROR: No work units found in plan. Expected '### Unit N: ...' headings." >&2
  exit 1
fi

# Extract feature name from plan title (first H1)
FEATURE_NAME=$(head -5 "$PLAN_PATH" | grep '^# ' | head -1 | sed 's/^# //' | sed 's/ — Loop Plan//' | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')
if [[ -z "$FEATURE_NAME" ]]; then
  FEATURE_NAME="orchestrated-build"
fi

WORKING_BRANCH="loop/${FEATURE_NAME}"

# ─── Create State Directory ───

STATE_DIR="${PROJECT_ROOT}/.claude/loop-orchestrator"
mkdir -p "${STATE_DIR}/units"

# Write config.json
cat > "${STATE_DIR}/config.json" <<CONFIGEOF
{
  "plan_path": "${PLAN_PATH}",
  "base_branch": "${BASE_BRANCH}",
  "working_branch": "${WORKING_BRANCH}",
  "clean_start_verified": true,
  "max_concurrent": ${MAX_CONCURRENT},
  "max_iterations": ${MAX_ITERATIONS},
  "max_retries": ${MAX_RETRIES},
  "user_approved_dod": false,
  "user_approved_concurrency": false,
  "test_command": "",
  "start_command": "",
  "_note_commands": "test_command and start_command are populated by the loopbuild SKILL during interactive setup (Step 3), not by this script",
  "has_ui": ${HAS_UI}
}
CONFIGEOF

# Write initial status.json
cat > "${STATE_DIR}/status.json" <<STATUSEOF
{
  "phase": "setup",
  "iteration": 0,
  "max_iterations": ${MAX_ITERATIONS},
  "plan_path": "${PLAN_PATH}",
  "units_total": ${UNIT_COUNT},
  "units_completed": 0,
  "units_in_progress": 0,
  "units_blocked": 0,
  "units_pending": ${UNIT_COUNT},
  "has_ui": ${HAS_UI},
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
STATUSEOF

# Extract Shared Interfaces section from plan
awk '/^## Shared Interfaces$/,/^## [^S]/' "$PLAN_PATH" | sed '$d' > "${STATE_DIR}/interfaces.md" 2>/dev/null || echo "# Shared Interfaces\n\nNone defined." > "${STATE_DIR}/interfaces.md"

# Extract Architectural Decisions section from plan
awk '/^## Architectural Decisions$/,/^## [^A]/' "$PLAN_PATH" | sed '$d' > "${STATE_DIR}/decisions.md" 2>/dev/null || echo "# Architectural Decisions\n\nNone defined." > "${STATE_DIR}/decisions.md"

# Extract Acceptance Tests section from plan
awk '/^## Acceptance Tests/,/^## [^A]/' "$PLAN_PATH" | sed '$d' > "${STATE_DIR}/acceptance-tests.md" 2>/dev/null || echo "# Acceptance Tests\n\nNone defined." > "${STATE_DIR}/acceptance-tests.md"

# Create per-unit directories
UNIT_NUM=0
while IFS= read -r line; do
  UNIT_NUM=$((UNIT_NUM + 1))
  # Extract unit name from "### Unit N: Name (estimated: X tasks)"
  UNIT_NAME=$(echo "$line" | sed 's/^### Unit [0-9]*: //' | sed 's/ (estimated:.*//' | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')
  UNIT_ID=$(printf "unit-%02d" "$UNIT_NUM")
  UNIT_DIR="${STATE_DIR}/units/${UNIT_ID}-${UNIT_NAME}"
  mkdir -p "$UNIT_DIR"

  # Write unit status.json
  cat > "${UNIT_DIR}/status.json" <<UNITEOF
{
  "id": "${UNIT_ID}",
  "name": "${UNIT_NAME}",
  "status": "pending",
  "worktree_path": "",
  "branch": "loop/${UNIT_ID}-${UNIT_NAME}",
  "retries": 0,
  "max_retries": ${MAX_RETRIES},
  "last_error": null,
  "simplify_done": false,
  "review_done": false,
  "tasks_total": 0,
  "tasks_completed": 0
}
UNITEOF

  # Extract unit section from plan into context.md
  # Get content from this unit heading until the next unit heading or end of units section
  UNIT_HEADING="### Unit ${UNIT_NUM}:"
  NEXT_HEADING="### Unit $((UNIT_NUM + 1)):"
  awk "/${UNIT_HEADING}/,/${NEXT_HEADING}|^## /" "$PLAN_PATH" | sed '$d' > "${UNIT_DIR}/context.md" 2>/dev/null || echo "# ${UNIT_NAME}\n\nNo context extracted." > "${UNIT_DIR}/context.md"

done < <(grep '^### Unit [0-9]' "$PLAN_PATH")

# ─── Output Setup Report ───

cat <<REPORTEOF
Claude Loop orchestrator initialized.

Plan:           ${PLAN_PATH}
Work units:     ${UNIT_COUNT}
Max concurrent: ${MAX_CONCURRENT}
Max iterations: ${MAX_ITERATIONS}
Max retries:    ${MAX_RETRIES}
Has UI:         ${HAS_UI}
Working branch: ${WORKING_BRANCH}
State dir:      .claude/loop-orchestrator/

IMPORTANT — Before the loop starts, the /loopbuild skill will:
1. Present work unit decomposition and ask you to approve concurrency
2. Present per-unit Definition of Done for your review and editing
3. Auto-detect test_command and start_command for your confirmation
4. Create the working branch and start the orchestrator loop

The orchestrator loop has NOT started yet. The skill handles the interactive
setup steps and then writes the loop-state.md file to activate the Stop hook.
REPORTEOF
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/setup-orchestrator.sh
```

- [ ] **Step 3: Test argument parsing (help flag)**

```bash
CLAUDE_PLUGIN_ROOT="$(pwd)" ./scripts/setup-orchestrator.sh --help
```

Expected: Help text output, exit 0.

- [ ] **Step 4: Test missing plan argument**

```bash
CLAUDE_PLUGIN_ROOT="$(pwd)" ./scripts/setup-orchestrator.sh 2>&1 || true
```

Expected: Error message about missing plan path.

- [ ] **Step 5: Commit**

```bash
git add scripts/setup-orchestrator.sh
git commit -m "feat: add setup-orchestrator.sh for state initialization"
```

---

### Task 5: Merge Worktrees Script

**Files:**
- Create: `scripts/merge-worktrees.sh`

- [ ] **Step 1: Write merge-worktrees.sh**

Create `scripts/merge-worktrees.sh`:

```bash
#!/bin/bash

# Claude Loop — Merge Worktrees
# Merges completed unit branches back into the working branch.
# Called by the orchestrator during the MERGING phase.

set -euo pipefail

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
STATE_DIR="${PROJECT_ROOT}/.claude/loop-orchestrator"
CONFIG_FILE="${STATE_DIR}/config.json"
LOG_FILE="${STATE_DIR}/orchestrator.log"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: No active orchestrator loop found." >&2
  exit 1
fi

WORKING_BRANCH=$(jq -r '.working_branch' "$CONFIG_FILE")
TEST_COMMAND=$(jq -r '.test_command // ""' "$CONFIG_FILE")

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" >> "$LOG_FILE" 2>/dev/null || true
  echo "$1"
}

# Ensure we're on the working branch
CURRENT=$(git branch --show-current)
if [[ "$CURRENT" != "$WORKING_BRANCH" ]]; then
  git checkout "$WORKING_BRANCH" 2>/dev/null || {
    echo "ERROR: Cannot checkout working branch: $WORKING_BRANCH" >&2
    exit 1
  }
fi

MERGE_FAILURES=0
MERGE_SUCCESSES=0

# Iterate over unit directories
for UNIT_DIR in "${STATE_DIR}/units"/*/; do
  if [[ ! -d "$UNIT_DIR" ]]; then
    continue
  fi

  UNIT_STATUS_FILE="${UNIT_DIR}/status.json"
  if [[ ! -f "$UNIT_STATUS_FILE" ]]; then
    continue
  fi

  STATUS=$(jq -r '.status' "$UNIT_STATUS_FILE")
  BRANCH=$(jq -r '.branch' "$UNIT_STATUS_FILE")
  UNIT_NAME=$(jq -r '.name' "$UNIT_STATUS_FILE")
  WORKTREE_PATH=$(jq -r '.worktree_path // ""' "$UNIT_STATUS_FILE")

  # Only merge completed units
  if [[ "$STATUS" != "done" ]]; then
    continue
  fi

  # Check if branch exists
  if ! git rev-parse --verify "$BRANCH" &>/dev/null; then
    log "WARNING: Branch $BRANCH for unit $UNIT_NAME does not exist, skipping"
    continue
  fi

  log "Merging ${UNIT_NAME} (${BRANCH})..."

  if git merge "$BRANCH" --no-edit 2>/dev/null; then
    log "  Merged ${UNIT_NAME} successfully"
    MERGE_SUCCESSES=$((MERGE_SUCCESSES + 1))

    # Clean up worktree if it exists
    if [[ -n "$WORKTREE_PATH" ]] && [[ -d "$WORKTREE_PATH" ]]; then
      git worktree remove "$WORKTREE_PATH" --force 2>/dev/null || true
    fi

    # Delete the unit branch
    git branch -d "$BRANCH" 2>/dev/null || true
  else
    log "  CONFLICT merging ${UNIT_NAME} — attempting auto-resolve"

    # Try auto-resolve: accept both changes where possible
    CONFLICTED_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null || echo "")

    if [[ -z "$CONFLICTED_FILES" ]]; then
      git commit --no-edit 2>/dev/null || true
      log "  Auto-resolved ${UNIT_NAME}"
      MERGE_SUCCESSES=$((MERGE_SUCCESSES + 1))
    else
      # Abort this merge — will need manual resolution
      git merge --abort 2>/dev/null || true
      log "  FAILED to merge ${UNIT_NAME} — conflicts in: ${CONFLICTED_FILES}"
      MERGE_FAILURES=$((MERGE_FAILURES + 1))

      # Update unit status to reflect merge failure
      jq '.status = "merge_conflict" | .last_error = "Merge conflict — requires manual resolution"' \
        "$UNIT_STATUS_FILE" > "${UNIT_STATUS_FILE}.tmp" && mv "${UNIT_STATUS_FILE}.tmp" "$UNIT_STATUS_FILE"
    fi
  fi
done

# Summary
log ""
log "Merge complete: ${MERGE_SUCCESSES} succeeded, ${MERGE_FAILURES} failed"

if [[ $MERGE_FAILURES -gt 0 ]]; then
  log "Some merges failed — orchestrator will escalate to user."
  exit 1
fi

# Run test suite if configured
if [[ -n "$TEST_COMMAND" ]]; then
  log ""
  log "Running test suite: ${TEST_COMMAND}"
  if eval "$TEST_COMMAND"; then
    log "Tests passed."
  else
    log "Tests FAILED after merge."
    exit 2
  fi
fi

exit 0
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/merge-worktrees.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/merge-worktrees.sh
git commit -m "feat: add merge-worktrees.sh for unit branch integration"
```

---

### Task 6: Loopplan Skill & Plan Template

**Files:**
- Create: `skills/loopplan/SKILL.md`
- Create: `templates/plan-template.md`

- [ ] **Step 1: Write the loopplan SKILL.md**

Create `skills/loopplan/SKILL.md`:

```markdown
---
name: loopplan
description: Create parallel-structured plans for orchestrated execution with /loopbuild. Use when the user wants to plan work for parallel subagent execution, mentions "loop plan", "parallel plan", or wants to structure work into independent units.
---

# Loop Plan — Parallel-Structured Planning

Create implementation plans specifically structured for parallel orchestrated execution via `/loopbuild`.

**Announce at start:** "I'm using the loopplan skill to create a parallel-structured implementation plan."

## How This Differs From Regular Plans

Regular plans produce sequential task lists. Loop plans produce:
- **Independent work units** that can execute in parallel worktrees
- **Shared interfaces** as explicit contracts between units
- **Acceptance tests** for Playwright verification
- **UI detection** that triggers the verification phase

## Process

### Step 1: Explore Codebase
- Read existing project structure, tech stack, patterns
- Check for CLAUDE.md, package.json, existing tests
- Understand what you're building on top of

### Step 2: Understand the Request
- What is being built?
- What are the natural boundaries?
- Is there a UI? (determines whether Playwright verification runs)

### Step 3: Define Interfaces FIRST
Before structuring work units, define the contracts between them:
- API contracts (endpoints, request/response shapes)
- Data schemas (tables, models)
- Component props (if UI)
- Shared types/enums

These go in the **Shared Interfaces** section. Every unit reads these.

### Step 4: Identify Independent Work Units
Decompose into 2-8 units that can run in parallel. Each unit must:
- Own its own files (no two units modify the same file)
- Be buildable and testable with only the interface contracts
- Not depend on another unit's output to start work

If true independence isn't possible, mark dependencies explicitly:
```
**Depends on:** Unit 1 must complete before this unit starts
```
The orchestrator will sequence dependent units.

### Step 5: Structure Each Work Unit
For each unit, provide:
- **Scope:** What it owns
- **Depends on interfaces:** Which shared interfaces it implements/consumes
- **Files:** Exact paths to create/modify
- **Tasks:** Full step-by-step with complete code blocks, exact file paths, commands with expected output. No placeholders. No "similar to Task N". Every step is self-contained.

Task granularity: each step is 2-5 minutes of work.

### Step 6: Write Acceptance Tests
If `Has UI: true`, write Playwright scenarios in natural language:
1. Navigate to [URL]
2. Click [element]
3. Fill in [field] with [value]
4. Verify: [expected outcome]

These become real Playwright tests during the VERIFYING phase.

### Step 7: Write Smoke Test Coverage
List routes/pages that should load without errors. The orchestrator auto-generates tests for these.

### Step 8: Self-Review — Independence Verification
Before saving, verify:
- [ ] No two units modify the same file (except shared config listed in interfaces)
- [ ] Each unit can be built in isolation with only interface contracts
- [ ] No unit depends on another unit's runtime output to start
- [ ] All shared types/interfaces are defined in the Shared Interfaces section
- [ ] No placeholders (TBD, TODO, "similar to", "implement later")
- [ ] Every step has complete code blocks
- [ ] Acceptance tests cover all user-facing flows

### Step 9: Save and Get Approval

Save to: `docs/loop-plans/YYYY-MM-DD-<feature>.md`

Use the plan template format from `${CLAUDE_PLUGIN_ROOT}/templates/plan-template.md`.

After saving, tell the user:
> "Plan saved to `docs/loop-plans/<filename>`. Please review, then run `/loopbuild <path>` to start orchestrated execution."

## Key Rules

- **Interfaces before units.** Design the contracts first, then the implementations.
- **No file overlap.** If two units need to touch the same file, either split the file or merge the units.
- **No placeholders.** Every step has real code, real commands, real expected output.
- **Flag UI explicitly.** `Has UI: true/false` in the plan header controls Playwright verification.
- **2-8 units.** Fewer than 2 isn't parallel. More than 8 is too much orchestration overhead.
```

- [ ] **Step 2: Write the plan template**

Create `templates/plan-template.md`:

```markdown
# [Feature Name] — Loop Plan

> **Execution:** Use `/loopbuild` to execute this plan.

**Goal:** [One sentence describing what this builds]
**Architecture:** [2-3 sentences about approach]
**Tech Stack:** [Key technologies/libraries]
**Has UI:** true/false

---

## Shared Interfaces

Contracts between work units. Each unit MUST respect these exactly.

### [Contract Type]: [Name]
[Exact specification — types, endpoints, schemas]

---

## Architectural Decisions

Decisions all units must follow.

- [Decision 1 — be specific, e.g., "Use Zod for all request validation"]
- [Decision 2]

---

## Work Units

### Unit 1: [Name] (estimated: N tasks)

**Scope:** [What this unit owns — be specific about boundaries]
**Depends on interfaces:** [List which shared interfaces it implements or consumes]
**Files:**
- Create: `exact/path/to/file.ext`
- Modify: `exact/path/to/existing.ext`
- Test: `exact/path/to/test.ext`

**Tasks:**

- [ ] **Step 1: [Action]**

```[language]
[Complete code — no placeholders]
```

- [ ] **Step 2: [Verify]**

Run: `[exact command]`
Expected: [exact expected output or behavior]

[Continue with all steps...]

### Unit 2: [Name] (estimated: N tasks)

[Same structure — fully self-contained, no "similar to Unit 1"]

---

## Acceptance Tests (Playwright)

User-facing scenarios that must pass for the feature to be done.

### Scenario 1: [User flow name]
1. Navigate to [URL]
2. [Action]
3. [Action]
4. Verify: [Expected outcome]

---

## Smoke Test Coverage

Pages/routes that should load without errors (auto-generated tests):
- GET [route] → [expected status], no console errors
```

- [ ] **Step 3: Commit**

```bash
git add skills/loopplan/SKILL.md templates/plan-template.md
git commit -m "feat: add loopplan skill and plan template"
```

---

### Task 7: Loopbuild Skill & Prompt Templates

**Files:**
- Create: `skills/loopbuild/SKILL.md`
- Create: `skills/loopbuild/orchestrator-prompt.md`
- Create: `skills/loopbuild/subagent-prompt.md`

- [ ] **Step 1: Write the loopbuild SKILL.md**

Create `skills/loopbuild/SKILL.md`:

```markdown
---
name: loopbuild
description: Execute a /loopplan via orchestrated parallel subagents in worktrees. Use when the user runs /loopbuild, wants to "execute the loop plan", "start the orchestrator", "run parallel build", or references a loop plan file.
---

# Loop Build — Orchestrated Parallel Execution

Execute a `/loopplan` by running an orchestrator Ralph loop that dispatches subagents to isolated git worktrees.

**Announce at start:** "I'm using the loopbuild skill to orchestrate parallel execution of this plan."

## Prerequisites

- A plan file created by `/loopplan` (passed as argument)
- Clean git working tree (enforced by setup script)
- Must be a git repository

## Setup Sequence

### Step 0: Run Setup Script

Execute the setup script to validate git, parse the plan, and create the state directory:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-orchestrator.sh" <PLAN_PATH> [OPTIONS]
```

This creates `.claude/loop-orchestrator/` with all state files but does NOT start the loop yet.

### Step 1: Present Decomposition for Approval

Read `.claude/loop-orchestrator/status.json` and all unit status files.

Present to the user:
```
Plan loaded: "[feature name]"
[N] work units identified. Has UI: [true/false]

Units:
  1. [unit-name] — [scope summary]
  2. [unit-name] — [scope summary]
  ...

Recommended concurrency: [min(N, 4)]
How many concurrent subagents? [default]:
```

Wait for user input. Update `config.json` with their choice. Set `user_approved_concurrency: true`.

### Step 2: Present Per-Unit Definition of Done

For each unit, draft a DoD from its tasks in `context.md`. Present all DoDs:

```
Definition of Done — review and edit:

Unit 1: [name]
  - [DoD item derived from tasks]
  - [DoD item]
  - Simplified and reviewed

Unit 2: [name]
  - [DoD item]
  ...

Edit any unit's DoD? (y/N):
```

If user wants to edit, update the relevant `context.md` file with their changes.
The DoD is stored as a markdown section at the end of each unit's `context.md`:

```markdown
## Definition of Done
- [ ] All N tasks completed
- [ ] All tests passing
- [ ] [Specific verifiable criterion]
- [ ] Simplified and reviewed
```

The subagent reads this section and must verify every checked item before reporting success.
Set `config.json` → `user_approved_dod: true`.

### Step 3: Detect and Confirm Commands

Auto-detect test and start commands:
- Check `package.json` for `scripts.test`, `scripts.dev`, `scripts.start`
- Check for `Makefile` targets
- Check for `pytest`, `cargo test`, `go test` patterns

Present:
```
Detected commands:
  Test:  npm test
  Start: npm run dev

Confirm or edit:
```

Update `config.json` with confirmed commands.

### Step 4: Create Working Branch

```bash
git checkout -b [working_branch]
```

### Step 5: Start the Orchestrator Loop

Write the loop state file that activates the Stop hook:

```bash
cat > .claude/loop-orchestrator/loop-state.md <<EOF
---
iteration: 1
max_iterations: [from config]
started_at: "[ISO timestamp]"
---

[Contents of orchestrator-prompt.md]
EOF
```

Update `status.json` → `phase: "executing"`.

The Stop hook will now intercept exit and feed the orchestrator prompt back each iteration.

## Orchestrator Behavior Per Iteration

After the loop starts, the orchestrator prompt (from `orchestrator-prompt.md`) drives all behavior. Read that file for the full decision logic per phase.

**You are now the orchestrator.** Each iteration:
1. Read all state files
2. Execute phase-appropriate actions
3. Update state files
4. Output status to user
5. When all phases complete, output `<promise>LOOP COMPLETE</promise>`

## Rules

- **Never skip the interactive setup steps.** User must approve concurrency, DoD, and commands.
- **Never dispatch more subagents than max_concurrent.**
- **Always update state files after every action.**
- **Escalate to user when a unit is blocked (retries exhausted).**
- **Output status every iteration so the user can see progress.**
```

- [ ] **Step 2: Write orchestrator-prompt.md**

Create `skills/loopbuild/orchestrator-prompt.md`:

```markdown
# Claude Loop Orchestrator — Iteration Prompt

You are the orchestrator of a parallel build. Read the state, make decisions, take actions, update state.

## Step 1: Read State

Read these files:
- `.claude/loop-orchestrator/status.json` — overall state and current phase
- `.claude/loop-orchestrator/config.json` — configuration
- All files in `.claude/loop-orchestrator/units/*/status.json` — per-unit state

## Step 2: Execute Based on Phase

### Phase: EXECUTING

1. **Count units by status:** pending, in_progress, done, blocked, failed
2. **Dispatch pending units** if `in_progress < max_concurrent` and `pending > 0`:
   - For each unit to dispatch:
     a. Read the unit's `context.md` for tasks and DoD
     b. Read `.claude/loop-orchestrator/interfaces.md`
     c. Read `.claude/loop-orchestrator/decisions.md`
     d. Create a subagent using the Agent tool with `isolation: "worktree"` and `mode: "bypassPermissions"`.
        The worktree is created automatically by the Agent tool in the system temp directory.
        Record the returned worktree path in the unit's `worktree_path` field.
     e. Read the subagent prompt template from `${CLAUDE_PLUGIN_ROOT}/skills/loopbuild/subagent-prompt.md`.
        Perform literal string replacement of all `{{variables}}` with actual content read from state files:
        - Unit name, scope, tasks, and DoD from `context.md`
        - Shared interfaces from `interfaces.md`
        - Architectural decisions from `decisions.md`
        - Retry context if `retries > 0` (include `last_error`)
     f. Update unit status to `in_progress` with `worktree_path` and `branch`
3. **Process returned subagents:**
   - If success: update unit status to `done`, set `simplify_done: true`, `review_done: true`
   - If failure: increment `retries`, set `last_error`, set status to `failed`
   - If `retries >= max_retries`: set status to `blocked`, report to user
4. **Check transition:** If all units are `done` → update `status.json` phase to `merging`
5. **If any units blocked:** Ask user for guidance. Options: retry, skip, cancel.

### Phase: MERGING

1. Run the merge script: `"${CLAUDE_PLUGIN_ROOT}/scripts/merge-worktrees.sh"`
   - Exit 0: all merges succeeded
   - Exit 1: some merges failed (conflicts) — read unit statuses for details, report to user
   - Exit 2: tests failed after merge — investigate and fix
2. If all merged and tests pass → update phase to `reviewing`
3. If conflicts → report conflicting files to user, attempt resolution or ask for help

### Phase: REVIEWING

1. Run the simplify skill on the full codebase: invoke `/simplify`
   - If skill not available, log "simplify skill not installed — skipping whole-codebase simplification" and continue
   - Simplify and review are quality gates, not correctness gates — their absence does not block completion
2. Run the code review on the full diff:
   - `git diff [base_branch]...[working_branch]`
   - Dispatch a code-reviewer agent to review the diff
   - If not available, log "code-review not installed — skipping whole-codebase review" and continue
3. If issues found: fix them, re-run review (max 2 rounds)
4. When clean (or skills unavailable) → update phase to `verifying` (if `has_ui: true`) or `done`

### Phase: VERIFYING

1. Read `.claude/loop-orchestrator/acceptance-tests.md`
2. Write Playwright test files:
   - Create test files from acceptance scenarios
   - Auto-generate smoke tests for routes not covered by acceptance tests:
     a. Detect framework: check for `next.config.*` (Next.js), `remix.config.*` (Remix), `vite.config.*` (Vite), or Express route files
     b. Enumerate routes:
        - Next.js: glob `app/**/page.{tsx,jsx,ts,js}` and `pages/**/*.{tsx,jsx,ts,js}`, convert file paths to URL paths
        - Remix: glob `app/routes/**/*.{tsx,jsx,ts,js}`, convert file paths to URL paths
        - Express/other: grep for `app.get\(`, `router.get\(` patterns, extract route strings
     c. Diff routes against acceptance test URLs to find uncovered routes
     d. For each uncovered route, generate a smoke test that:
        - Navigates to the route
        - Asserts response status 200
        - Listens for console errors and asserts none
        - Checks page is not blank (body has content)
3. Start the application using `start_command` from config
4. Install Playwright if needed: `npx playwright install --with-deps chromium`
5. Run tests: `npx playwright test`
6. If all pass → update phase to `done`
7. If failures:
   - Analyze failure (wrong selector in test? or bug in code?)
   - Fix and re-run (max 3 rounds)
   - If still failing → escalate to user with screenshots and details

### Phase: DONE

1. Output the completion summary:
   ```
   Claude Loop — Complete

   Units: [N] completed
   Iterations: [N] used
   Time: [elapsed]
   Branch: [working_branch] (ready for PR)
   ```
2. Output: `<promise>LOOP COMPLETE</promise>`

## Step 3: Output Status

Every iteration, output a status line:

```
Loop iteration [N] | Phase: [PHASE] | [completed]/[total] units done[, N blocked]
  [per-unit status lines]
```

## Rules

- Read state FIRST, then act. Never assume state from previous iterations.
- Update state files AFTER every action. State on disk is the source of truth.
- Never dispatch more subagents than `max_concurrent`.
- Always use `isolation: "worktree"` when dispatching subagents.
- If stuck or uncertain, ask the user rather than guessing.
- When all work is done, output `<promise>LOOP COMPLETE</promise>` — and ONLY when it is genuinely complete.
```

- [ ] **Step 3: Write subagent-prompt.md**

Create `skills/loopbuild/subagent-prompt.md`:

```markdown
# Subagent Work Unit Prompt Template

This is a reference template. The orchestrator reads this file, then performs
literal string replacement of all {{variables}} with actual content from state
files when building the `prompt` parameter for the Agent tool call. This is NOT
a templating engine — the orchestrator reads the state files, reads this template,
and constructs the final prompt string in its Agent tool invocation.

---

## Rendered Prompt:

You are a subagent working on one unit of a parallel build. Complete all your tasks, verify the Definition of Done, then report back.

### Your Assignment: {{unit_name}}

**Scope:** {{unit_scope}}

### Shared Interfaces — DO NOT DEVIATE

These are contracts between all work units. Implement them exactly as specified.

{{interfaces_md_content}}

### Architectural Decisions — FOLLOW THESE

{{decisions_md_content}}

### Your Tasks

Work through these in order. Run tests after each task.

{{unit_tasks_from_context_md}}

### Definition of Done

You MUST verify EVERY item before reporting success:

{{unit_dod_from_context_md}}

Additionally:
- Run the simplify skill on your changes (invoke /simplify). If the skill is not available, skip this step.
- Run a code review on your changes (use the code-reviewer agent). If not available, skip this step.
- Commit all changes to your branch with a descriptive message.

{{#if retry_context}}
### Previous Attempt Failed

This is retry {{retry_number}} of {{max_retries}}. The previous attempt failed with:

```
{{last_error}}
```

Fix the issue above, then complete all remaining tasks.
{{/if}}

### Rules

1. ONLY modify files listed in your scope. Do not touch other files.
2. Respect shared interfaces EXACTLY. Do not change the contracts.
3. If you need something from another unit that isn't available, mock or stub it using the interface contract.
4. If you are truly blocked on something outside your scope, clearly report:
   - What you need
   - Which interface or external dependency is the issue
   - What you've tried
5. Run tests frequently. Do not accumulate untested changes.
6. Commit your work before finishing — all changes must be on your branch.
```

- [ ] **Step 4: Commit**

```bash
git add skills/loopbuild/SKILL.md skills/loopbuild/orchestrator-prompt.md skills/loopbuild/subagent-prompt.md
git commit -m "feat: add loopbuild skill with orchestrator and subagent prompts"
```

---

### Task 8: Commands

**Files:**
- Create: `commands/loopplan.md`
- Create: `commands/loopbuild.md`
- Create: `commands/loopstatus.md`
- Create: `commands/loopcancel.md`
- Create: `commands/loopupdate.md`

- [ ] **Step 1: Write loopplan.md command**

Create `commands/loopplan.md`:

```markdown
---
description: "Create a parallel-structured plan for orchestrated execution with /loopbuild"
allowed-tools: ["Read", "Write", "Edit", "Glob", "Grep", "Bash", "Agent"]
---

# Loop Plan Command

Use the loopplan skill to create a parallel-structured implementation plan.

Invoke the skill: Use the Skill tool with skill name "loopplan".

After the skill completes, remind the user:
> To execute this plan, run: `/loopbuild <path-to-plan>`
```

- [ ] **Step 2: Write loopbuild.md command**

Create `commands/loopbuild.md`:

```markdown
---
description: "Execute a /loopplan via orchestrated parallel subagents in worktrees"
argument-hint: "PLAN_PATH [--max-concurrent N] [--max-iterations N] [--max-retries N]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-orchestrator.sh:*)", "Read", "Write", "Edit", "Glob", "Grep", "Bash", "Agent"]
---

# Loop Build Command

Execute the setup script to initialize the orchestrator:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-orchestrator.sh" $ARGUMENTS
```

After setup completes, invoke the loopbuild skill using the Skill tool with skill name "loopbuild".

The skill handles the interactive setup steps (concurrency approval, DoD review, command detection) and then starts the orchestrator loop.
```

- [ ] **Step 3: Write loopstatus.md command**

Create `commands/loopstatus.md`:

```markdown
---
description: "Check progress of active Claude Loop orchestration"
allowed-tools: ["Read", "Bash", "Glob"]
---

# Loop Status Command

Check if an orchestrator loop is active and report its status.

1. Check if `.claude/loop-orchestrator/config.json` exists.
   - If not: report "No active Claude Loop orchestration."

2. Read `.claude/loop-orchestrator/status.json` and report:
   - Current phase
   - Iteration count
   - Units summary (total, completed, in_progress, blocked, pending)
   - Time elapsed since `started_at`

3. Read each unit's `status.json` in `.claude/loop-orchestrator/units/*/` and report:
   - Unit name and status
   - Retry count if > 0
   - Last error if any
   - Whether simplify/review are done

4. If any units are blocked, highlight them with their error details.

Format the output clearly:

```
Claude Loop Status
Phase:     [phase] (iteration [N]/[max])
Elapsed:   [time]
Progress:  [completed]/[total] units

Units:
  [status-icon] [name]: [status] ([tasks_completed]/[tasks_total] tasks)
  ...

[If blocked units exist:]
Blocked:
  [name]: [last_error]
```
```

- [ ] **Step 4: Write loopcancel.md command**

Create `commands/loopcancel.md`:

```markdown
---
description: "Cancel active Claude Loop orchestration"
allowed-tools: ["Read", "Bash", "Glob"]
---

# Loop Cancel Command

Cancel an active orchestrator loop and clean up resources.

1. Check if `.claude/loop-orchestrator/config.json` exists.
   - If not: report "No active Claude Loop orchestration to cancel."

2. Read `.claude/loop-orchestrator/status.json` for the current state.
   - Record: phase, iteration, units completed.

3. Read config.json for worktree information.

4. Clean up worktrees for any in_progress units:
   - Read each unit's `status.json` for `worktree_path`
   - If worktree exists: `git worktree remove <path> --force`

5. Remove the loop state file:
   ```bash
   rm -f .claude/loop-orchestrator/loop-state.md
   ```

6. Remove the entire state directory:
   ```bash
   rm -rf .claude/loop-orchestrator
   ```

7. Report:
   ```
   Claude Loop cancelled.
   Phase was: [phase] (iteration [N])
   Units completed before cancel: [N]/[total]
   Worktrees cleaned up: [N]
   ```

8. Note: Unit branches are NOT deleted. The user can inspect or cherry-pick from them.
```

- [ ] **Step 5: Write loopupdate.md command**

Create `commands/loopupdate.md`:

```markdown
---
description: "Update Claude Loop plugin to latest version from GitHub"
allowed-tools: ["Read", "Bash"]
---

# Loop Update Command

Update the Claude Loop plugin to the latest version.

1. **Check for active loop:**
   - If `.claude/loop-orchestrator/config.json` exists:
     Report: "Cannot update while a loop is running. Run /loopcancel first or wait for completion."
     STOP — do not proceed.

2. **Read current version:**
   ```bash
   cat "${CLAUDE_PLUGIN_ROOT}/VERSION"
   ```

3. **Check latest version on GitHub:**
   - Read repository URL from `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json`
   - Extract owner/repo
   - Fetch latest release: `gh api repos/<owner>/<repo>/releases/latest --jq '.tag_name'`
   - If fetch fails, try: `curl -sf https://api.github.com/repos/<owner>/<repo>/releases/latest | jq -r '.tag_name'`
   - If both fail: report "Could not check for updates. Check your network connection."

4. **Compare versions:**
   - If current == latest: "You're already on the latest version (v[version])."
   - If current < latest: proceed to step 5.

5. **Show what changed:**
   - Fetch CHANGELOG from GitHub: `gh api repos/<owner>/<repo>/contents/CHANGELOG.md --jq '.content' | base64 -d`
   - Show entries between current and latest version.

6. **Confirm with user:**
   "Update claude-loop from v[current] to v[latest]? (y/N)"
   - Wait for user confirmation.

7. **Perform update:**
   - The exact update mechanism depends on how the plugin was installed.
   - If installed via Claude Code plugin manager: guide the user to reinstall.
   - If cloned from git: `cd ${CLAUDE_PLUGIN_ROOT} && git pull origin main`
   - Verify: `cat ${CLAUDE_PLUGIN_ROOT}/VERSION` matches expected version.

8. **Report:**
   "Updated to v[latest]. Restart your Claude Code session to use the new version."
```

- [ ] **Step 6: Commit all commands**

```bash
git add commands/loopplan.md commands/loopbuild.md commands/loopstatus.md commands/loopcancel.md commands/loopupdate.md
git commit -m "feat: add all slash commands (loopplan, loopbuild, loopstatus, loopcancel, loopupdate)"
```

---

### Task 9: Integration Verification

**Files:** None (verification only)

This task runs after all others complete. It verifies the plugin is structurally correct and all files are in place.

- [ ] **Step 1: Verify file structure matches spec**

```bash
find . -type f -not -path './.git/*' | sort
```

Expected files (all present):
```
./.claude-plugin/plugin.json
./CHANGELOG.md
./VERSION
./commands/loopbuild.md
./commands/loopcancel.md
./commands/loopplan.md
./commands/loopstatus.md
./commands/loopupdate.md
./hooks/check-update.sh
./hooks/hooks.json
./hooks/orchestrator-stop-hook.sh
./scripts/merge-worktrees.sh
./scripts/setup-orchestrator.sh
./skills/loopbuild/SKILL.md
./skills/loopbuild/orchestrator-prompt.md
./skills/loopbuild/subagent-prompt.md
./skills/loopplan/SKILL.md
./templates/plan-template.md
```

- [ ] **Step 2: Verify all shell scripts are executable**

```bash
test -x hooks/orchestrator-stop-hook.sh && echo "stop-hook: OK" || echo "stop-hook: NOT EXECUTABLE"
test -x hooks/check-update.sh && echo "check-update: OK" || echo "check-update: NOT EXECUTABLE"
test -x scripts/setup-orchestrator.sh && echo "setup: OK" || echo "setup: NOT EXECUTABLE"
test -x scripts/merge-worktrees.sh && echo "merge: OK" || echo "merge: NOT EXECUTABLE"
```

Expected: all OK.

- [ ] **Step 3: Verify plugin.json is valid JSON**

```bash
jq . .claude-plugin/plugin.json > /dev/null && echo "plugin.json: valid" || echo "plugin.json: INVALID"
```

Expected: valid.

- [ ] **Step 4: Verify hooks.json is valid JSON and references correct paths**

```bash
jq . hooks/hooks.json > /dev/null && echo "hooks.json: valid" || echo "hooks.json: INVALID"
jq -r '.hooks.Stop[0].hooks[0].command' hooks/hooks.json
jq -r '.hooks.SessionStart[0].hooks[0].command' hooks/hooks.json
```

Expected: valid JSON, paths contain `${CLAUDE_PLUGIN_ROOT}`.

- [ ] **Step 5: Verify VERSION matches plugin.json version**

```bash
FILE_VERSION=$(cat VERSION | tr -d '[:space:]')
JSON_VERSION=$(jq -r '.version' .claude-plugin/plugin.json)
if [[ "$FILE_VERSION" == "$JSON_VERSION" ]]; then
  echo "Versions match: $FILE_VERSION"
else
  echo "VERSION MISMATCH: file=$FILE_VERSION json=$JSON_VERSION"
fi
```

Expected: Versions match.

- [ ] **Step 6: Verify skill frontmatter has required fields**

```bash
for skill in skills/*/SKILL.md; do
  echo "=== $skill ==="
  head -5 "$skill" | grep -E '^(name|description):' || echo "MISSING FRONTMATTER"
done
```

Expected: both skills have `name:` and `description:` fields.

- [ ] **Step 7: Verify stop hook exits cleanly with no active loop**

```bash
echo '{}' | PROJECT_ROOT="$(pwd)" bash hooks/orchestrator-stop-hook.sh 2>/dev/null
echo "Exit code: $?"
```

Expected: exit 0.

- [ ] **Step 8: Final commit (if any fixes needed)**

```bash
git status
```

If clean: done. If changes: commit with descriptive message.

---

## Parallelism Map

```
Task 1: Plugin Scaffold (MUST complete first)
    │
    ├── Task 2: Stop Hook ─────────────┐
    ├── Task 3: Session Start Hook ────┤
    ├── Task 4: Setup Script ──────────┤ All independent,
    ├── Task 5: Merge Script ──────────┤ can run in parallel
    ├── Task 6: Loopplan Skill ────────┤
    ├── Task 7: Loopbuild Skill ───────┤
    ├── Task 8: Commands ──────────────┘
    │
    └── Task 9: Integration Verification (MUST run last)
```

Tasks 2-8 have zero file overlap and can all be dispatched simultaneously.
