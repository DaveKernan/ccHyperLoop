#!/bin/bash

# ccHyperLoop — Merge Worktrees
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

update_unit_status() {
  local status_file="$1" jq_expr="$2" unit_name="$3"
  if jq "$jq_expr" "$status_file" > "${status_file}.tmp"; then
    mv "${status_file}.tmp" "$status_file"
  else
    log "ERROR: Failed to update status JSON for ${unit_name}"
    rm -f "${status_file}.tmp"
  fi
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

for UNIT_DIR in "${STATE_DIR}/units"/*/; do
  UNIT_STATUS_FILE="${UNIT_DIR}/status.json"
  [[ ! -f "$UNIT_STATUS_FILE" ]] && continue

  STATUS=$(jq -r '.status' "$UNIT_STATUS_FILE")
  BRANCH=$(jq -r '.branch' "$UNIT_STATUS_FILE")
  UNIT_NAME=$(jq -r '.name' "$UNIT_STATUS_FILE")
  WORKTREE_PATH=$(jq -r '.worktree_path // ""' "$UNIT_STATUS_FILE")

  [[ "$STATUS" != "done" ]] && continue

  if ! git rev-parse --verify "$BRANCH" &>/dev/null; then
    log "WARNING: Branch $BRANCH for unit $UNIT_NAME does not exist, skipping"
    continue
  fi

  log "Merging ${UNIT_NAME} (${BRANCH})..."

  if git merge "$BRANCH" --no-edit 2>/dev/null; then
    log "  Merged ${UNIT_NAME} successfully"
    MERGE_SUCCESSES=$((MERGE_SUCCESSES + 1))
  else
    CONFLICTED_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null || echo "")
    git merge --abort 2>/dev/null || true

    if [[ -z "$CONFLICTED_FILES" ]]; then
      log "  FAILED to merge ${UNIT_NAME} — non-conflict merge failure (possible hook failure)"
    else
      log "  FAILED to merge ${UNIT_NAME} — conflicts in: ${CONFLICTED_FILES}"
    fi

    MERGE_FAILURES=$((MERGE_FAILURES + 1))
    update_unit_status "$UNIT_STATUS_FILE" \
      '.status = "merge_conflict" | .last_error = "Merge conflict — requires manual resolution"' \
      "$UNIT_NAME"
  fi

  # Always clean up worktree after merge attempt (success or failure)
  if [[ -n "$WORKTREE_PATH" ]] && [[ -d "$WORKTREE_PATH" ]]; then
    git worktree remove "$WORKTREE_PATH" --force 2>/dev/null || true
  fi
  git branch -d "$BRANCH" 2>/dev/null || true
done

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
  if timeout 600 sh -c "$TEST_COMMAND"; then
    log "Tests passed."
  else
    EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 124 ]]; then
      log "Tests TIMEOUT after 10 minutes."
    else
      log "Tests FAILED after merge."
    fi
    exit 2
  fi
fi

exit 0
