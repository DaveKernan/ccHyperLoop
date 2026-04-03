---
description: "Update ccHyperLoop plugin to latest version from GitHub"
allowed-tools: ["Read", "Bash"]
---

# Loop Update Command

Update the ccHyperLoop plugin to the latest version from GitHub.

## Instructions

1. **Check for active loop**: Verify `.claude/loop-orchestrator/config.json` does NOT exist. If it does, REFUSE the update and report: "Cannot update while loop is running. Please cancel the active loop first with /loopcancel."

2. **Read current version**: Read the current version from `${CLAUDE_PLUGIN_ROOT}/VERSION`.

3. **Check latest version on GitHub**: Attempt to fetch the latest version:
   - First try: `gh api repos/<owner>/<repo>/releases/latest --jq '.tag_name'`
   - Fallback: `curl -s https://api.github.com/repos/<owner>/<repo>/releases/latest | jq -r '.tag_name'`
   - If both fail: Report a network error and stop.

4. **Compare versions**: If the current version matches the latest version, report: "Already on latest version (vX.Y.Z)." and stop.

5. **Show changes**: Display the CHANGELOG diff between the current and latest versions so the user can see what changed.

6. **Confirm update**: Ask the user to confirm they want to proceed with the update before making any changes.

7. **Perform update**: Depending on the install method:
   - If installed via git clone: Run `git pull` in the plugin root directory.
   - If installed via other method: Guide the user through reinstallation steps.

8. **Verify update**: Read `${CLAUDE_PLUGIN_ROOT}/VERSION` again and confirm it matches the expected latest version. Report success or failure.
