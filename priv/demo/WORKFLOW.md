---
tracker:
  kind: "memory"

polling:
  interval_ms: 3600000

workspace:
  root: .shep/demo_worktrees

agent:
  command: "priv/demo/agent.sh"
  max_concurrent: 1
  max_turns: 1
  idle_timeout_ms: 60000
  total_timeout_ms: 120000

hooks:
  hook_timeout_ms: 10000

staging:
  base_branch: "main"
  pr_target: "main"
---

# Shep Demo Workflow

Config for `just shep demo`: memory tracker, stub agent, no PR creation.
