#!/bin/bash

# ccHyperLoop Orchestrator Stop Hook
# Prevents session exit when an orchestrator loop is active.
# Reads loop state, checks completion, and feeds the orchestrator prompt back.

set -euo pipefail

# Safety: if anything goes wrong in the hook, allow exit rather than locking the session
trap 'exit 0' ERR

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
  echo "WARNING: ccHyperLoop orchestrator: $msg" >&2
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
  echo "ccHyperLoop: Max iterations ($MAX_ITERATIONS) reached. Stopping orchestrator."
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
    echo "ccHyperLoop: Orchestration complete."
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

# Update iteration in frontmatter only (avoid matching "iteration:" in prompt content)
TEMP_FILE="${LOOP_STATE_FILE}.tmp.$$"
awk -v next="$NEXT_ITERATION" '
  /^---$/ { fm++; print; next }
  fm == 1 && /^iteration:/ { print "iteration: " next; next }
  { print }
' "$LOOP_STATE_FILE" > "$TEMP_FILE"
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

SYSTEM_MSG="ccHyperLoop iteration ${NEXT_ITERATION}${UNITS_SUMMARY} | To complete: output <promise>LOOP COMPLETE</promise>"

jq -n \
  --arg prompt "$PROMPT_TEXT" \
  --arg msg "$SYSTEM_MSG" \
  '{
    "decision": "block",
    "reason": $prompt,
    "systemMessage": $msg
  }'

exit 0
