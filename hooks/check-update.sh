#!/usr/bin/env bash
set -euo pipefail

# Async SessionStart hook: check GitHub for newer versions of claude-loop.
# Silently exits 0 on ANY failure — never blocks session start.

trap 'exit 0' ERR

# --- Read local version ---
LOCAL_VERSION=""
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]] && [[ -f "${CLAUDE_PLUGIN_ROOT}/VERSION" ]]; then
  LOCAL_VERSION="$(cat "${CLAUDE_PLUGIN_ROOT}/VERSION" 2>/dev/null)" || true
fi
if [[ -z "$LOCAL_VERSION" ]] && [[ -f "$(dirname "$0")/../VERSION" ]]; then
  LOCAL_VERSION="$(cat "$(dirname "$0")/../VERSION" 2>/dev/null)" || true
fi
[[ -z "$LOCAL_VERSION" ]] && exit 0

# --- Read repo URL from plugin.json ---
PLUGIN_JSON=""
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]] && [[ -f "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json" ]]; then
  PLUGIN_JSON="${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json"
elif [[ -f "$(dirname "$0")/../.claude-plugin/plugin.json" ]]; then
  PLUGIN_JSON="$(dirname "$0")/../.claude-plugin/plugin.json"
fi
[[ -z "$PLUGIN_JSON" ]] && exit 0

command -v jq >/dev/null 2>&1 || exit 0
REPO_URL="$(jq -r '.repository // empty' "$PLUGIN_JSON" 2>/dev/null)" || exit 0
[[ -z "$REPO_URL" ]] && exit 0

# --- Extract owner/repo from URL (handles https://github.com/owner/repo) ---
OWNER_REPO="$(echo "$REPO_URL" | sed -n 's|.*github\.com/\([^/]*/[^/]*\).*|\1|p' | sed 's/\.git$//')"
[[ -z "$OWNER_REPO" ]] && exit 0

# --- Fetch latest release tag ---
REMOTE_TAG=""

# Try gh CLI first
if command -v gh >/dev/null 2>&1; then
  REMOTE_TAG="$(gh api "repos/${OWNER_REPO}/releases/latest" --jq '.tag_name' 2>/dev/null)" || true
fi

# Fall back to curl
if [[ -z "$REMOTE_TAG" ]] && command -v curl >/dev/null 2>&1; then
  REMOTE_TAG="$(curl -sf --max-time 5 \
    "https://api.github.com/repos/${OWNER_REPO}/releases/latest" 2>/dev/null \
    | jq -r '.tag_name // empty' 2>/dev/null)" || true
fi

[[ -z "$REMOTE_TAG" ]] && exit 0

# --- Strip leading 'v' and compare with sort -V ---
REMOTE_VERSION="${REMOTE_TAG#v}"
[[ -z "$REMOTE_VERSION" ]] && exit 0

# If remote <= local, nothing to do
HIGHER="$(printf '%s\n%s\n' "$LOCAL_VERSION" "$REMOTE_VERSION" | sort -V | tail -n1)"
[[ "$HIGHER" == "$LOCAL_VERSION" ]] && exit 0
[[ "$REMOTE_VERSION" == "$LOCAL_VERSION" ]] && exit 0

# --- Remote is newer — emit hook output ---
cat <<EOF
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"Claude Loop v${REMOTE_VERSION} available (you have v${LOCAL_VERSION}). Run /loopupdate to update."}}
EOF

exit 0
