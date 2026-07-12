#!/usr/bin/env bash
# Stub agent for `just shep demo`. Stands in for a real coding agent so the
# full orchestration loop (worktree, dispatch, streaming, completion) can be
# seen without an agent CLI, labels, or a target repo. Also the script behind
# the README GIF recording, so its output is part of the public face.
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
# -c identity: the demo must commit even on machines with no git identity
git -c user.name='Shep Demo' -c user.email='demo@shep.invalid' \
  commit -q -m "chore: let Shep graze in PASTURE.md"
echo "Committed PASTURE.md."

echo '<completion>{"type": "complete", "summary": "Grazed PASTURE.md and committed the change.", "verify": ["orchestrator dispatched into an isolated worktree", "stdout streamed line-buffered", "a real commit landed on the task branch", "completion signal parsed"]}</completion>'
