# Watch what a factory agent is doing in real time
[group('factory')]
factory-watch issue-number:
  #!/usr/bin/env bash
  set -euo pipefail
  DIR="$HOME/.claude/projects/-Users-craigruks-code-factory-worktrees-factory-{{issue-number}}"
  echo "Waiting for agent session..."
  until ls "$DIR"/*.jsonl 2>/dev/null | head -1 | grep -q .; do sleep 1; done
  LATEST=$(ls -t "$DIR"/*.jsonl | head -1)
  echo "Tailing: $LATEST"
  tail -f "$LATEST" | jq -r --unbuffered \
    'if .type == "assistant" then
       (.message.content[]? | select(.type == "text") | .text)
     elif .type == "tool_use" then
       "→ \(.tool_name // "tool")"
     else empty end'

# Run the factory quality gate (format + credo + tests)
[group('factory')]
factory-quality:
  cd factory && eval "$(mise env)" && mix quality

# Run a factory agent on a specific issue
[group('factory')]
factory-agent issue-number:
  cd factory && eval "$(mise env)" && mix factory.agent --issue {{issue-number}}

# List factory templates and running tasks
[group('factory')]
factory-list:
  cd factory && eval "$(mise env)" && mix factory.list

# Generate triage checklist from in-review issues
[group('factory')]
factory-triage:
  cd factory && eval "$(mise env)" && mix factory.triage

# Promote staging to main and transition in-review issues
[group('factory')]
factory-promote:
  cd factory && eval "$(mise env)" && mix factory.promote

# Bootstrap a factory worktree (install deps so agents can run quality checks)
[group('factory')]
factory-bootstrap worktree-path:
  #!/usr/bin/env bash
  set -euo pipefail
  WT="{{worktree-path}}"
  if [ ! -d "$WT" ]; then echo "Worktree not found: $WT"; exit 1; fi
  MISE_LOCAL="$(git worktree list | head -1 | awk '{print $1}')/../threshold-platform.wt/deployment/.mise.local.toml"
  if [ -f "$MISE_LOCAL" ]; then
    cp "$MISE_LOCAL" "$WT/.mise.local.toml"
    mise trust "$WT" 2>/dev/null || true
  fi
  echo "==> Installing dependencies in $WT..."
  eval "$(cd "$WT" && mise env 2>/dev/null || true)" && cd "$WT" && pnpm install --frozen-lockfile
  echo "==> Worktree bootstrapped."

# Start the factory orchestrator (interactive — polls tracker, dispatches agents)
[group('factory')]
factory-start:
  cd factory && eval "$(mise env)" && iex -S mix

# Run factory headless in foreground
[group('factory')]
factory-run:
  cd factory && eval "$(mise env)" && elixir -S mix run --no-halt

# Start factory orchestrator in background — kills any existing instance first
[group('factory')]
factory-daemon:
  #!/usr/bin/env bash
  set -e
  cd factory && eval "$(mise env)"
  mkdir -p .factory
  # Kill any existing orchestrator
  if [ -f .factory/orchestrator.pid ]; then
    OLD_PID=$(cat .factory/orchestrator.pid)
    if kill -0 "$OLD_PID" 2>/dev/null; then
      kill "$OLD_PID" 2>/dev/null
      sleep 1
      kill -9 "$OLD_PID" 2>/dev/null || true
    fi
    rm -f .factory/orchestrator.pid
  fi
  nohup elixir -S mix run --no-halt \
    > .factory/orchestrator.log 2>&1 &
  echo $! > .factory/orchestrator.pid
  echo "Orchestrator started (pid $!)"
  echo "  just factory-view    — watch orchestrator + tasks"
  echo "  just factory-daemon-stop    — stop orchestrator"

# Stop the factory orchestrator
[group('factory')]
factory-daemon-stop:
  #!/usr/bin/env bash
  set -e
  PID_FILE="factory/.factory/orchestrator.pid"
  if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
      kill "$PID"
      echo "Orchestrator stopped (pid $PID)"
    else
      echo "Orchestrator not running (stale pid $PID)"
    fi
    rm -f "$PID_FILE"
  else
    echo "No orchestrator pid file found"
  fi

# Check factory status as JSON (running tasks, claimed, totals)
[group('factory')]
factory-status:
  cd factory && eval "$(mise env)" && mix factory.status 2>/dev/null

# Pause a running factory task (preserves worktree + session)
[group('factory')]
factory-pause task-id:
  cd factory && eval "$(mise env)" && mix factory.pause --task {{task-id}}

# Resume a paused factory task (continues Claude session)
[group('factory')]
factory-resume task-id:
  cd factory && eval "$(mise env)" && mix factory.resume --task {{task-id}}

# Take over a running task — pause, open Claude session, offer resume on exit
[group('factory')]
factory-takeover task-id:
  #!/usr/bin/env bash
  set -e
  cd factory && eval "$(mise env)"
  PAUSE_RESULT=$(mix factory.pause --task {{task-id}})
  WORKTREE=$(echo "$PAUSE_RESULT" | jq -r '.worktree_path // empty')
  if [ -z "$WORKTREE" ]; then
    echo "Could not find worktree for task {{task-id}}"
    exit 1
  fi
  echo "Opening Claude session in $WORKTREE..."
  cd "$WORKTREE" && claude --resume "factory-{{task-id}}"
  echo ""
  read -p "Resume factory task {{task-id}}? [y/n] " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    cd factory && mix factory.resume --task {{task-id}}
  else
    echo "Task {{task-id}} remains paused. Run 'just factory-resume {{task-id}}' when ready."
  fi

# Tail a specific factory task's raw output
[group('factory')]
factory-tail task-id:
  tail -f factory/.factory/runs/{{task-id}}.stdout.log

# Watch factory in tmux: orchestrator log + task panes that auto-spawn as tasks dispatch
[group('factory')]
factory-view:
  #!/usr/bin/env bash
  set -e
  cd factory
  tmux kill-session -t foreman 2>/dev/null || true
  LOG=".factory/orchestrator.log"
  touch "$LOG"
  SEEN=$(mktemp)
  trap "rm -f $SEEN" EXIT
  # Pane 0: orchestrator log + background watcher that spawns task panes
  tmux new-session -d -s foreman -n foreman "bash -c ' \
    SEEN=\"$SEEN\" && \
    _relayout() { \
      W=\$(tmux display -t foreman -p \"#{client_width}\"); \
      H=\$(tmux display -t foreman -p \"#{client_height}\"); \
      if [ \"\$W\" -gt \"\$((H * 2))\" ]; then \
        tmux select-layout -t foreman main-vertical 2>/dev/null; \
      else \
        tmux select-layout -t foreman main-horizontal 2>/dev/null; \
      fi; \
    } && \
    ( while true; do \
        for f in .factory/runs/*.stdout.log; do \
          [ -f \"\$f\" ] || continue; \
          TASK=\$(basename \"\$f\" .stdout.log); \
          if ! grep -q \"^\$TASK\$\" \"\$SEEN\" 2>/dev/null; then \
            echo \"\$TASK\" >> \"\$SEEN\"; \
            tmux split-window -t foreman \
              \"echo \\\"=== Task \$TASK ===\\\" && tail -f \$f | sed /^===.TASK/q\"; \
            _relayout; \
          fi; \
        done; \
        sleep 2; \
      done ) & \
    echo \"=== Orchestrator ==\" && tail -f $LOG \
  '"
  # Re-layout on terminal resize
  tmux set-hook -t foreman client-resized \
    "run-shell 'W=\$(tmux display -p \"#{client_width}\"); H=\$(tmux display -p \"#{client_height}\"); if [ \$W -gt \$((H * 2)) ]; then tmux select-layout -t foreman main-vertical; else tmux select-layout -t foreman main-horizontal; fi'"
  tmux attach -t foreman
