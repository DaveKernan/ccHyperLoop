---
description: "Check progress of active Claude Loop orchestration"
allowed-tools: ["Read", "Bash", "Glob"]
---

# Loop Status Command

Check and report the current state of an active Claude Loop orchestration.

## Instructions

1. **Check for active orchestration**: Verify `.claude/loop-orchestrator/config.json` exists. If not, report: "No active Claude Loop orchestration."

2. **Read orchestration status**: Read `.claude/loop-orchestrator/status.json` and report:
   - Current phase
   - Current iteration
   - Unit counts (total, completed, in_progress, pending, failed)
   - Elapsed time since start

3. **Read individual unit statuses**: For each unit, read its `status.json` and report:
   - Unit name
   - Current status
   - Number of retries attempted
   - Any errors encountered
   - Whether simplify/review steps have been completed

4. **Highlight blocked units**: For any units with errors or in a blocked/failed state, show the error details prominently so the user can take action.

5. **Format output clearly**: Use icons and structured formatting for readability:
   - Completed units
   - In-progress units
   - Pending units
   - Failed/blocked units with error details
