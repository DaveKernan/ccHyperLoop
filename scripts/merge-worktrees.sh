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
      log "  WARNING: Merge failed but no conflicts detected — possible hook failure"
      git merge --abort 2>/dev/null || true
      log "  FAILED to merge ${UNIT_NAME} — non-conflict merge failure"
      MERGE_FAILURES=$((MERGE_FAILURES + 1))
      jq '.status = "merge_conflict" | .last_error = "Merge failed without conflicts — possible hook failure"' \
        "$UNIT_STATUS_FILE" > "${UNIT_STATUS_FILE}.tmp" && mv "${UNIT_STATUS_FILE}.tmp" "$UNIT_STATUS_FILE"
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
