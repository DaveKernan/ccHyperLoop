---
description: "Cancel active ccHyperLoop orchestration"
allowed-tools: ["Read", "Bash", "Glob"]
---

# Loop Cancel Command

Cancel an active ccHyperLoop orchestration and clean up resources.

## Instructions

1. **Check for active orchestration**: Verify `.claude/loop-orchestrator/config.json` exists. If not, report: "No active orchestration to cancel."

2. **Read current state**: Read `.claude/loop-orchestrator/status.json` to understand the current phase, iteration, and unit statuses before cancellation.

3. **Clean up worktrees**: For any units with status `in_progress`, remove their git worktrees:
   ```
   git worktree remove --force <worktree-path>
   ```

4. **Remove loop state**: Delete the `loop-state.md` file if it exists.

5. **Remove orchestrator directory**: Remove the entire `.claude/loop-orchestrator/` directory and its contents.

6. **Report cancellation summary**:
   - Phase at time of cancellation
   - Iteration at time of cancellation
   - Number of units that were completed before cancellation
   - Number of worktrees cleaned up

7. **Important note**: Inform the user that unit branches are NOT deleted. The user can inspect or cherry-pick from them as needed.
