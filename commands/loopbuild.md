---
description: "Execute a /loopplan via orchestrated parallel subagents in worktrees"
argument-hint: "PLAN_PATH [--max-concurrent N] [--max-iterations N] [--max-retries N]"
allowed-tools: ["Read", "Write", "Edit", "Glob", "Grep", "Bash", "Agent"]
---

# Loop Build Command

## Step 1: Setup Orchestrator

Execute the setup script with the provided arguments:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-orchestrator.sh" $ARGUMENTS
```

Run this via the Bash tool. This script parses the plan file, creates the orchestrator directory structure, and initializes worktrees.

## Step 2: Start the Loop

After setup completes successfully, invoke the loopbuild skill via the Skill tool with skill name "loopbuild".

The skill handles interactive setup and starts the loop, managing parallel subagent execution across worktrees.
