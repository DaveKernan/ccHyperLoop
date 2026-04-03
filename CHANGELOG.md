# Changelog

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
