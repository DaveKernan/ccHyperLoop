---
description: "Execute a /loopplan via orchestrated parallel subagents in worktrees"
argument-hint: "PLAN_PATH [--max-concurrent N] [--max-iterations N] [--max-retries N]"
allowed-tools: ["Read", "Write", "Edit", "Glob", "Grep", "Bash", "Agent"]
---

# Loop Build Command

## Step 1: Setup Orchestrator

Execute the setup script with the user's arguments via the Bash tool. Substitute the user's actual plan path and any flags they provided:

```
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-orchestrator.sh" <plan-path> [--max-concurrent N] [--max-iterations N] [--max-retries N]
```

For example, if the user ran `/loopbuild docs/loop-plans/2026-04-03-feature.md --max-concurrent 6`, run:
```
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-orchestrator.sh" docs/loop-plans/2026-04-03-feature.md --max-concurrent 6
```

This script parses the plan file, creates the orchestrator directory structure, and initializes state.

## Step 2: Start the Loop

After setup completes successfully, invoke the loopbuild skill via the Skill tool with skill name "loopbuild".

The skill handles interactive setup and starts the loop, managing parallel subagent execution across worktrees.
