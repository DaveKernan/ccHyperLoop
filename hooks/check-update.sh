#!/usr/bin/env bash
set -euo pipefail

# Async SessionStart hook: check GitHub for newer versions of ccHyperLoop.
# Silently exits 0 on ANY failure — never blocks session start.

trap 'exit 0' ERR

# --- Resolve plugin root ---
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$0")/..}"

# --- Read local version ---
LOCAL_VERSION="$(cat "${PLUGIN_ROOT}/VERSION" 2>/dev/null || true)"
[[ -z "$LOCAL_VERSION" ]] && exit 0

# --- Read repo URL from plugin.json ---
command -v jq >/dev/null 2>&1 || exit 0
REPO_URL="$(jq -r '.repository // empty' "${PLUGIN_ROOT}/.claude-plugin/plugin.json" 2>/dev/null)" || exit 0
[[ -z "$REPO_URL" ]] && exit 0

# --- Extract owner/repo ---
OWNER_REPO="$(echo "$REPO_URL" | sed -n 's|.*github\.com/\([^/]*/[^/]*\).*|\1|p; s/\.git$//')"
[[ -z "$OWNER_REPO" ]] && exit 0

# --- Fetch latest release tag (gh first, curl fallback) ---
REMOTE_TAG=""
if command -v gh >/dev/null 2>&1; then
  REMOTE_TAG="$(gh api "repos/${OWNER_REPO}/releases/latest" --jq '.tag_name' 2>/dev/null)" || true
fi
if [[ -z "$REMOTE_TAG" ]] && command -v curl >/dev/null 2>&1; then
  REMOTE_TAG="$(curl -sf --max-time 5 \
    "https://api.github.com/repos/${OWNER_REPO}/releases/latest" 2>/dev/null \
    | jq -r '.tag_name // empty' 2>/dev/null)" || true
fi
[[ -z "$REMOTE_TAG" ]] && exit 0

# --- Compare versions ---
REMOTE_VERSION="${REMOTE_TAG#v}"
[[ -z "$REMOTE_VERSION" ]] && exit 0

HIGHER="$(printf '%s\n%s\n' "$LOCAL_VERSION" "$REMOTE_VERSION" | sort -V | tail -n1)"
[[ "$HIGHER" != "$REMOTE_VERSION" || "$REMOTE_VERSION" == "$LOCAL_VERSION" ]] && exit 0

# --- Remote is newer ---
cat <<EOF
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"ccHyperLoop v${REMOTE_VERSION} available (you have v${LOCAL_VERSION}). Run /loopupdate to update."}}
EOF
