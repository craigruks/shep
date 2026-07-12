---
tracker:
  kind: "github"
  repo: "your-org/your-repo"

polling:
  interval_ms: 30000

workspace:
  root: ~/code/shep_worktrees

agent:
  command: "claude"
  max_concurrent: 3
  max_turns: 10
  idle_timeout_ms: 600000
  total_timeout_ms: 1200000

hooks:
  on_worktree_ready: "eval \"$(mise env 2>/dev/null)\" && pnpm install --frozen-lockfile"
  hook_timeout_ms: 180000

staging:
  base_branch: "staging"
  pr_target: "staging"
---

# Shep Workflow

Agent orchestration config. YAML front matter is hot-reloaded every 1s.
