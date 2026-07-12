# Shep: autonomous agent orchestration.
# Usage: just shep <command> [id]
#
#   canonical        herding alias    action
#   ---------        -------------    ------
#   up               wake             start orchestrator (background, idempotent)
#   down             rest             stop orchestrator
#   start            -                start orchestrator (interactive iex)
#   run <issue>      fetch <issue>    dispatch an agent on one issue
#   queue            pen              list templates + queued candidates
#   ps               flock            status JSON (running, paused, claimed, totals)
#   pause <id>       heel <id>        pause task (preserves worktree + session)
#   resume <id>      send <id>        resume paused task (--continue)
#   attach <id>      take <id>        shepherd steps in: pause → Claude session → offer resume
#   logs <id>        watch <id>       tail a task's raw stdout
#   session <issue>  trail <issue>    pretty-tail the agent's Claude session
#   kill <id>        drop <id>        kill a stuck agent (no retry, worktree kept)
#   view             field            tmux: orchestrator + auto-spawning task panes
#   promote          home             promote staging → main, transition issues
#   triage           -                triage checklist from in-review issues
#   quality          -                format + credo --strict + tests
#   bootstrap <path> -                install deps in an agent worktree

shep cmd id="":
  #!/usr/bin/env bash
  set -euo pipefail
  eval "$(mise env 2>/dev/null || true)"

  # herding aliases → canonical
  case "{{cmd}}" in
    wake)  CMD=up ;;
    rest)  CMD=down ;;
    fetch) CMD=run ;;
    pen)   CMD=queue ;;
    flock) CMD=ps ;;
    heel)  CMD=pause ;;
    send)  CMD=resume ;;
    take)  CMD=attach ;;
    watch) CMD=logs ;;
    trail) CMD=session ;;
    field) CMD=view ;;
    drop)  CMD=kill ;;
    home)  CMD=promote ;;
    bark)  CMD=speak ;;
    *)     CMD="{{cmd}}" ;;
  esac

  need_id() { if [ -z "{{id}}" ]; then echo "Usage: just shep $CMD <id>"; exit 1; fi; }

  case "$CMD" in
    up)
      mkdir -p .shep
      if [ -f .shep/orchestrator.pid ]; then
        OLD_PID=$(cat .shep/orchestrator.pid)
        if kill -0 "$OLD_PID" 2>/dev/null; then
          kill "$OLD_PID" 2>/dev/null; sleep 1
          kill -9 "$OLD_PID" 2>/dev/null || true
        fi
        rm -f .shep/orchestrator.pid
      fi
      nohup elixir -S mix run --no-halt > .shep/orchestrator.log 2>&1 &
      echo $! > .shep/orchestrator.pid
      echo "Shep is awake (pid $!)"
      echo "  just shep view     watch the field"
      echo "  just shep down     stop"
      ;;
    down)
      PID_FILE=".shep/orchestrator.pid"
      if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if kill -0 "$PID" 2>/dev/null; then
          kill "$PID"; echo "Shep is resting (pid $PID stopped)"
        else
          echo "Orchestrator not running (stale pid $PID)"
        fi
        rm -f "$PID_FILE"
      else
        echo "No orchestrator pid file found"
      fi
      ;;
    start)
      iex -S mix
      ;;
    run)
      need_id
      mix shep.agent --issue {{id}}
      ;;
    queue)
      mix shep.list
      ;;
    ps)
      mix shep.status 2>/dev/null
      ;;
    pause)
      need_id
      mix shep.pause --task {{id}}
      ;;
    resume)
      need_id
      mix shep.resume --task {{id}}
      ;;
    attach)
      need_id
      PAUSE_RESULT=$(mix shep.pause --task {{id}})
      WORKTREE=$(echo "$PAUSE_RESULT" | jq -r '.worktree_path // empty')
      if [ -z "$WORKTREE" ]; then
        echo "Could not find worktree for task {{id}}"; exit 1
      fi
      echo "Shepherd stepping in: opening Claude session in $WORKTREE..."
      ROOT="$PWD"
      cd "$WORKTREE" && claude --resume "shep-{{id}}"
      echo ""
      read -p "Send Shep back out on task {{id}}? [y/n] " -n 1 -r
      echo
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        cd "$ROOT" && mix shep.resume --task {{id}}
      else
        echo "Task {{id}} remains paused. Run 'just shep resume {{id}}' when ready."
      fi
      ;;
    logs)
      need_id
      tail -f .shep/runs/{{id}}.stdout.log
      ;;
    session)
      need_id
      DIR="$HOME/.claude/projects/-Users-craigruks-code-shep-worktrees-shep-{{id}}"
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
      ;;
    view)
      tmux kill-session -t shep 2>/dev/null || true
      LOG=".shep/orchestrator.log"
      touch "$LOG"
      SEEN=$(mktemp)
      trap "rm -f $SEEN" EXIT
      # Pane 0: orchestrator log + background watcher that spawns task panes
      tmux new-session -d -s shep -n shep "bash -c ' \
        SEEN=\"$SEEN\" && \
        _relayout() { \
          W=\$(tmux display -t shep -p \"#{client_width}\"); \
          H=\$(tmux display -t shep -p \"#{client_height}\"); \
          if [ \"\$W\" -gt \"\$((H * 2))\" ]; then \
            tmux select-layout -t shep main-vertical 2>/dev/null; \
          else \
            tmux select-layout -t shep main-horizontal 2>/dev/null; \
          fi; \
        } && \
        ( while true; do \
            for f in .shep/runs/*.stdout.log; do \
              [ -f \"\$f\" ] || continue; \
              TASK=\$(basename \"\$f\" .stdout.log); \
              if ! grep -q \"^\$TASK\$\" \"\$SEEN\" 2>/dev/null; then \
                echo \"\$TASK\" >> \"\$SEEN\"; \
                tmux split-window -t shep \
                  \"echo \\\"=== Task \$TASK ===\\\" && tail -f \$f | sed /^===.TASK/q\"; \
                _relayout; \
              fi; \
            done; \
            sleep 2; \
          done ) & \
        echo \"=== Orchestrator ==\" && tail -f $LOG \
      '"
      # Re-layout on terminal resize
      tmux set-hook -t shep client-resized \
        "run-shell 'W=\$(tmux display -p \"#{client_width}\"); H=\$(tmux display -p \"#{client_height}\"); if [ \$W -gt \$((H * 2)) ]; then tmux select-layout -t shep main-vertical; else tmux select-layout -t shep main-horizontal; fi'"
      tmux attach -t shep
      ;;
    kill)
      need_id
      mix shep.kill --task {{id}}
      ;;
    promote)
      mix shep.promote
      ;;
    triage)
      mix shep.triage
      ;;
    quality)
      mix quality
      ;;
    speak)
      echo "ᵂᴼᴼᶠ  ∪･ｪ･∪"
      if command -v say >/dev/null 2>&1; then
        say -v Albert "woof! woof!" 2>/dev/null || say "woof woof"
        sleep 0.2
        # somewhere out in the field, the flock answers
        say -v Bahh "baaaah" 2>/dev/null || true
      else
        printf '\a'
        echo "WOOF! (no say command on this OS, imagine something majestic)"
      fi
      ;;
    bootstrap)
      need_id
      WT="{{id}}"
      if [ ! -d "$WT" ]; then echo "Worktree not found: $WT"; exit 1; fi
      echo "==> Installing dependencies in $WT..."
      cd "$WT"
      eval "$(mise env 2>/dev/null || true)"
      if [ -f pnpm-lock.yaml ]; then pnpm install --frozen-lockfile
      elif [ -f package-lock.json ]; then npm ci
      elif [ -f mix.exs ]; then mix deps.get
      else echo "No recognized lockfile. Configure hooks.on_worktree_ready in WORKFLOW.md"; fi
      echo "==> Worktree bootstrapped."
      ;;
    *)
      echo "Shep: you're the shepherd, Shep works the flock."
      echo ""
      echo "Usage: just shep <command> [id]"
      echo ""
      echo "  canonical        herding alias    action"
      echo "  up               wake             start orchestrator (background)"
      echo "  down             rest             stop orchestrator"
      echo "  start            -                start orchestrator (interactive iex)"
      echo "  run <issue>      fetch <issue>    dispatch an agent on one issue"
      echo "  queue            pen              list templates + queued candidates"
      echo "  ps               flock            status JSON"
      echo "  pause <id>       heel <id>        pause task (preserves worktree + session)"
      echo "  resume <id>      send <id>        resume paused task"
      echo "  attach <id>      take <id>        shepherd steps in (pause → Claude → resume)"
      echo "  logs <id>        watch <id>       tail a task's raw stdout"
      echo "  session <issue>  trail <issue>    pretty-tail the agent's Claude session"
      echo "  view             field            tmux: orchestrator + task panes"
      echo "  kill <id>        drop <id>        kill a stuck agent (no retry, worktree kept)"
      echo "  promote          home             promote staging → main"
      echo "  triage           -                triage checklist from in-review issues"
      echo "  quality          -                format + credo --strict + tests"
      echo "  bootstrap <path> -                install deps in an agent worktree"
      echo "  speak            bark             woof (you know, for morale)"
      [ "{{cmd}}" = "help" ] || exit 1
      ;;
  esac
