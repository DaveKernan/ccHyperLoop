# Changelog

## 0.2.0 — 2026-04-03

- Encouragement Mode — optional reminder appended to subagent work instructions
- Token Optimization — orchestrator selects model (opus/sonnet/haiku) per unit based on complexity
- Scaffold-first dispatch — shared types, config, and stubs committed before subagent dispatch
- DOCUMENTING phase — cleanup artifacts, verify README, fix orphaned refs before declaring done
- Hardened shell scripts: jq-based JSON generation, test timeout, safe eval replacement, jq error handling
- Comprehensive README with installation, architecture, troubleshooting, and state directory reference
- Fixed marketplace.json for plugin discovery
- Two simplify + review passes applied

## 0.1.0 — 2026-04-03

Initial release.

- `/loopplan` skill for parallel-structured planning
- `/loopbuild` skill for orchestrated parallel execution
- Orchestrator Ralph loop with Stop hook
- Git worktree isolation per work unit
- Shared state directory (`.claude/loop-orchestrator/`)
- Subagent dispatch with retry (3x) and escalation
- Per-unit simplify and review gates
- Whole-codebase simplify and review after merge
- Playwright acceptance + smoke test verification
- Async version check on session start
- `/loopstatus`, `/loopcancel`, `/loopupdate` commands
