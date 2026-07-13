# Shep: autonomous agent orchestration.
# Usage: just shep <command> [id]
#
#   canonical        herding alias    action
#   ---------        -------------    ------
#   demo             trial            full loop with a stub agent, zero setup
#   build            -                build the mix release → bin/shep (run once, and after code changes)
#   up               wake             start daemon via bin/shep (background, idempotent)
#   down             rest             stop daemon gracefully (bin/shep stop)
#   restart          -                restart daemon in place (bin/shep restart)
#   console          whistle          live IEx into the running flock (bin/shep remote)
#   start            -                start orchestrator from source (interactive iex, dev)
#   run <issue>      fetch <issue>    dispatch an agent on one issue
#   queue            pen              list templates + queued candidates
#   ps               flock            status JSON (running, paused, claimed)
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
    home)    CMD=promote ;;
    bark)    CMD=speak ;;
    trial)   CMD=demo ;;
    whistle) CMD=console ;;
    *)       CMD="{{cmd}}" ;;
  esac

  need_id() { if [ -z "{{id}}" ]; then echo "Usage: just shep $CMD <id>"; exit 1; fi; }

  # The built release is the shipped artifact; `just shep build` produces it.
  BIN="_build/prod/rel/shep/bin/shep"
  need_release() {
    if [ ! -x "$BIN" ]; then
      echo "Release not built. Run: just shep build"; exit 1
    fi
  }

  case "$CMD" in
    build)
      MIX_ENV=prod mix release --overwrite
      ;;
    up)
      need_release
      mkdir -p .shep
      # Idempotent: a live daemon owns the `shep` node name; don't start a second.
      if "$BIN" pid >/dev/null 2>&1; then
        echo "Shep is already awake (pid $("$BIN" pid))"
        exit 0
      fi
      # `start` (not `daemon`) so logs land in .shep/orchestrator.log — the
      # surface `just shep view` and the handler playbook tail. nohup detaches
      # it; `bin/shep stop` later tears the VM down gracefully (:init.stop),
      # draining agents instead of the old kill -9 that orphaned Ports.
      nohup "$BIN" start > .shep/orchestrator.log 2>&1 &
      sleep 2
      if PID=$("$BIN" pid 2>/dev/null); then
        echo "Shep is awake (pid $PID)"
      else
        echo "Shep is waking (check: just shep ps)"
      fi
      echo "  just shep view     watch the field"
      echo "  just shep down     stop"
      ;;
    down)
      if [ -x "$BIN" ] && "$BIN" pid >/dev/null 2>&1; then
        "$BIN" stop && echo "Shep is resting"
      else
        echo "Orchestrator not running"
      fi
      ;;
    restart)
      need_release
      "$BIN" restart && echo "Shep restarted"
      ;;
    console)
      need_release
      exec "$BIN" remote
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
      # derive the Claude projects dir from WORKFLOW.md workspace.root
      ROOT=$(sed -n 's/^ *root: *//p' WORKFLOW.md | head -1)
      ROOT="${ROOT/#\~/$HOME}"
      ENC=$(printf '%s' "$ROOT/shep_{{id}}" | sed 's/[/_.]/-/g')
      DIR="$HOME/.claude/projects/$ENC"
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
    demo)
      mix shep.demo
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
      echo "  demo             trial            full loop with a stub agent, zero setup"
      echo "  build            -                build the mix release → bin/shep"
      echo "  up               wake             start daemon via bin/shep (background)"
      echo "  down             rest             stop daemon gracefully"
      echo "  restart          -                restart daemon in place"
      echo "  console          whistle          live IEx into the running flock"
      echo "  start            -                start orchestrator from source (interactive iex)"
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
