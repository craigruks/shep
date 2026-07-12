# Shep

Elixir/OTP agent orchestration. Polls a tracker, spawns coding agents
(Claude Code / Codex) in git worktrees, supervises through completion,
handles CI failures. You're the shepherd; Shep works the flock.

## Commands

```bash
mix test                            # All tests
mix format --check-diff             # Format check
mix credo --strict                  # Lint (includes custom checks)
mix quality                         # All three above
```

## Code Style

- Dry, elegant, modular. Files < 300 lines.
- Structs with `@enforce_keys`, not bare maps.
- `with` for fallible chains, pipes for pure transforms.
- `@impl true` on every callback.
- Guard clauses on public function heads.
- Never create atoms from external input.
- `Logger.metadata/1` per process for task correlation.
- `@moduledoc` and `@doc` on every public module and function.
- `Stream` for large file reads (lazy, constant memory).
- Pattern match > conditional. Behaviours for polymorphism.

## Architecture

```
Shep.Application (Supervisor, one_for_one)
├── Registry (Shep.Registry)       O(1) agent lookup
├── Shep.Config (GenServer)        hot-reload WORKFLOW.md
├── Task.Supervisor                spawns agent tasks
└── Shep.Orchestrator (GenServer)  poll/dispatch/monitor
```

## Key Patterns

- **Error kernel**: Orchestrator never crashes from agent work.
  All risky ops happen in agent runner Tasks.
- **ETS for reads**: Status reads come from the `:shep_state` ETS
  table, zero contention with orchestrator.
- **Telemetry spans**: `[:shep, :agent, :start|:stop]`,
  `[:shep, :orchestrator, :dispatch]`.
- **Port zombies**: Line-buffered delivery via `{:line, 65536}`.
  Explicit Port.close + kill on timeout.
- **Graceful shutdown**: `terminate/2` drains running agents.
  Child spec `shutdown: 30_000`.

## Human Control Surface

One dispatcher recipe: `just shep <command> [id]`. Every canonical
command has a herding alias. Both hit the same handler.

```bash
just shep up              # wake:    start orchestrator (background, idempotent)
just shep down            # rest:    stop orchestrator
just shep run <issue>     # fetch:   dispatch an agent on one issue
just shep queue           # pen:     list templates + queued candidates
just shep ps              # flock:   status JSON: running, paused, claimed, totals
just shep pause <id>      # heel:    pause task (preserves worktree + session)
just shep resume <id>     # send:    resume paused task (--continue)
just shep attach <id>     # take:    shepherd steps in: pause → Claude → offer resume
just shep logs <id>       # watch:   tail a task's raw stdout
just shep session <issue> # trail:   pretty-tail the agent's Claude session
just shep kill <id>       # drop:    kill a stuck agent (no retry, worktree kept)
just shep view            # field:   tmux: orchestrator + auto-spawning task panes
just shep promote         # home:    promote staging → main, transition issues
just shep help            #           full command table
```

`attach`/`take` is the human-takeover surface (formerly "foreman"):
the shepherd steps onto the field, works the session interactively,
then sends Shep back out.

Control commands reach a running daemon over distributed Erlang (node
`shep@<host>`, started by `just shep up`). With no daemon they fall back
to a local one-shot node. `just shep demo` runs the whole loop with a
stub agent and a memory tracker; nothing is pushed.

## Agent Selection

`shep:codex` label on GitHub issue → Codex CLI instead of Claude.
Agent-specific modules: `AgentRunner.Claude`, `AgentRunner.Codex`.
Claude sessions use `--name "shep-{id}"` for persistence.

## Pause/Resume

Orchestrator tracks `paused: %{id => PausedTask}`. Pause kills
the agent process but preserves worktree + Claude session name.
Resume dispatches into existing worktree with `--continue`.

## Test Policy

- Mirrored structure: `lib/shep/*.ex` → `test/shep/*_test.exs`
- Pure-function tests: `async: true` (completion, prompt, buffer)
- Integration tests: `async: false` (orchestrator, worktree)
- No mocking framework: behaviours + test adapters

## Operating Shep as an outer agent (the handler)

Shep supervises known failure modes (crash, stall, red CI). A Claude
session operating Shep owns the unknown ones: auth, config drift, new
failure classes. Day to day: routine runs need no observer (Slack pings
on stall/failure); sit resident only for first runs on a new repo or
after config changes.

Playbook:

- Start: `SHEP_WORKFLOW=<path> just shep up`, then monitor
  `.shep/orchestrator.log` with a FILTERED tail (verdict lines, not
  per-poll noise).
- Push rejected with GH007: the target repo's `user.email` is private.
  Fix `git -C <workspace.repo> config user.email` to the noreply
  address. SSH agents do not reach the daemon; use
  `gh auth setup-git` plus an https `insteadOf` rewrite.
- Task failed and worktree preserved: diagnose in the worktree, fix the
  environment, then re-queue by flipping the issue label back to `shep`
  (remove `shep:in-progress`). cleanup_stale rebuilds the worktree.
- Prime directive: every intervention ends as a commit. A Shep code
  fix, a config change, or a line in this playbook. Never fix the same
  exception twice by hand.
