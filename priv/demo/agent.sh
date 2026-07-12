#!/usr/bin/env bash
# Stub agent for `just shep demo`. Stands in for a real coding agent so the
# full orchestration loop (worktree, dispatch, streaming, completion) can be
# seen without an agent CLI, labels, or a target repo.
set -euo pipefail

lines=(
  "Reading the briefing..."
  "Inspecting the worktree..."
  "Making the change (pretend furiously typing)..."
  "Running the checks..."
  "All green. Wrapping up."
)

for line in "${lines[@]}"; do
  echo "$line"
  sleep 0.4
done

# make a real, minimal change so the branch has a diff worth a PR
echo "🐑 Grazed by Shep on $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> PASTURE.md
git add PASTURE.md
git commit -q -m "chore: let Shep graze in PASTURE.md"
echo "Committed PASTURE.md."

echo '<completion>{"type": "complete", "summary": "Grazed PASTURE.md and committed the change.", "verify": ["orchestrator dispatched into an isolated worktree", "stdout streamed line-buffered", "a real commit landed on the task branch", "completion signal parsed"]}</completion>'
