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
