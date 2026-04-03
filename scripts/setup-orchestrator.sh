#!/bin/bash

# ccHyperLoop — Setup Orchestrator
# Validates git hygiene, parses the plan, creates state directory,
# and writes the loop state file to start the orchestrator Ralph loop.

set -euo pipefail

# ─── Argument Parsing ───

PLAN_PATH=""
MAX_CONCURRENT=4
MAX_ITERATIONS=50
MAX_RETRIES=3

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      cat << 'HELP'
ccHyperLoop Orchestrator Setup

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
jq -n \
  --arg plan_path "$PLAN_PATH" \
  --arg base_branch "$BASE_BRANCH" \
  --arg working_branch "$WORKING_BRANCH" \
  --argjson max_concurrent "$MAX_CONCURRENT" \
  --argjson max_iterations "$MAX_ITERATIONS" \
  --argjson max_retries "$MAX_RETRIES" \
  --argjson has_ui "$HAS_UI" \
  '{plan_path: $plan_path, base_branch: $base_branch, working_branch: $working_branch, clean_start_verified: true, max_concurrent: $max_concurrent, max_iterations: $max_iterations, max_retries: $max_retries, user_approved_dod: false, user_approved_concurrency: false, encouragement_enabled: false, test_command: "", start_command: "", has_ui: $has_ui}' \
  > "${STATE_DIR}/config.json"

# Write initial status.json
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -n \
  --argjson max_iterations "$MAX_ITERATIONS" \
  --arg plan_path "$PLAN_PATH" \
  --argjson units_total "$UNIT_COUNT" \
  --argjson has_ui "$HAS_UI" \
  --arg started_at "$STARTED_AT" \
  '{phase: "setup", iteration: 0, max_iterations: $max_iterations, plan_path: $plan_path, units_total: $units_total, units_completed: 0, units_in_progress: 0, units_blocked: 0, units_pending: $units_total, has_ui: $has_ui, started_at: $started_at}' \
  > "${STATE_DIR}/status.json"

# Extract plan sections — use explicit heading names to avoid overlap between
# sections that share first letters (e.g., "Architectural Decisions" and "Acceptance Tests")
extract_section() {
  local heading="$1" output="$2" fallback_title="$3"
  awk -v h="$heading" '
    $0 ~ "^## " h { found=1; print; next }
    found && /^## / { exit }
    found { print }
  ' "$PLAN_PATH" > "$output" 2>/dev/null
  if [[ ! -s "$output" ]]; then
    printf '# %s\n\nNone defined.\n' "$fallback_title" > "$output"
  fi
}

extract_section "Shared Interfaces" "${STATE_DIR}/interfaces.md" "Shared Interfaces"
extract_section "Architectural Decisions" "${STATE_DIR}/decisions.md" "Architectural Decisions"
extract_section "Acceptance Tests" "${STATE_DIR}/acceptance-tests.md" "Acceptance Tests"

# Create per-unit directories
UNIT_NUM=0
while IFS= read -r line; do
  UNIT_NUM=$((UNIT_NUM + 1))
  # Extract unit name from "### Unit N: Name (estimated: X tasks)"
  UNIT_NAME=$(echo "$line" | sed -E 's/^### Unit [0-9]+: //; s/ \(estimated:.*//' | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')
  UNIT_ID=$(printf "unit-%02d" "$UNIT_NUM")
  UNIT_DIR="${STATE_DIR}/units/${UNIT_ID}-${UNIT_NAME}"
  mkdir -p "$UNIT_DIR"

  # Write unit status.json
  jq -n \
    --arg id "$UNIT_ID" \
    --arg name "$UNIT_NAME" \
    --arg branch "loop/${UNIT_ID}-${UNIT_NAME}" \
    --argjson max_retries "$MAX_RETRIES" \
    '{id: $id, name: $name, status: "pending", worktree_path: "", branch: $branch, retries: 0, max_retries: $max_retries, last_error: null, simplify_done: false, review_done: false, tasks_total: 0, tasks_completed: 0}' \
    > "${UNIT_DIR}/status.json"

  # Extract unit section from plan into context.md
  # Get content from this unit heading until the next unit heading or end of units section
  UNIT_HEADING="### Unit ${UNIT_NUM}:"
  NEXT_HEADING="### Unit $((UNIT_NUM + 1)):"
  awk "/${UNIT_HEADING}/,/${NEXT_HEADING}|^## /" "$PLAN_PATH" | sed '$d' > "${UNIT_DIR}/context.md" 2>/dev/null || printf '# %s\n\nNo context extracted.\n' "$UNIT_NAME" > "${UNIT_DIR}/context.md"

done < <(grep '^### Unit [0-9]' "$PLAN_PATH")

# ─── Output Setup Report ───

cat <<REPORTEOF
ccHyperLoop orchestrator initialized.

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
