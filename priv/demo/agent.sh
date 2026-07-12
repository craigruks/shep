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

echo '<completion>{"type": "complete", "summary": "Demo task complete. A real agent would have committed changes here.", "verify": ["orchestrator dispatched into an isolated worktree", "stdout streamed line-buffered", "completion signal parsed"]}</completion>'
