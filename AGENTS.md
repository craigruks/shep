# Dark Factory (factory/)

Elixir/OTP agent orchestration. Polls tracker, spawns Claude Code agents
in git worktrees, supervises through completion, handles CI failures.

## Boundary

Elixir is for orchestration only. No TS imports — the boundary is
process-level (CLI child processes), not module-level.

## Commands

```bash
cd factory && mix test              # All tests
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
Factory.Application (Supervisor, one_for_one)
├── Registry (Factory.Registry)     — O(1) agent lookup
├── Factory.Config (GenServer)      — hot-reload WORKFLOW.md
├── Task.Supervisor                 — spawns agent tasks
└── Factory.Orchestrator (GenServer) — poll/dispatch/monitor
```

## Key Patterns

- **Error kernel**: Orchestrator never crashes from agent work.
  All risky ops happen in agent runner Tasks.
- **ETS for reads**: Dashboard reads from `:factory_state` ETS
  table, zero contention with orchestrator.
- **Telemetry spans**: `[:factory, :agent, :start|:stop]`,
  `[:factory, :orchestrator, :dispatch]`.
- **Port zombies**: Line-buffered delivery via `{:line, 65536}`.
  Explicit Port.close + kill on timeout.
- **Graceful shutdown**: `terminate/2` drains running agents.
  Child spec `shutdown: 30_000`.

## Foreman (Human Control Surface)

Operational recipes live in `just/factory.just`. Key commands:

```bash
just factory-daemon          # Start orchestrator (background, idempotent)
just factory-daemon-stop         # Stop orchestrator
just factory-view         # tmux: orchestrator + auto-spawning task panes
just factory-tail <id>    # Tail a single task's stdout
just factory-pause <id>   # Pause task (preserves worktree + session)
just factory-resume <id>  # Resume paused task (--continue)
just factory-takeover <id># Pause → interactive Claude → offer resume
just factory-status       # JSON: running, paused, claimed, totals
```

## Agent Selection

`factory:codex` label on GitHub issue → Codex CLI instead of Claude.
Agent-specific modules: `AgentRunner.Claude`, `AgentRunner.Codex`.
Claude sessions use `--name "factory-{id}"` for persistence.

## Pause/Resume

Orchestrator tracks `paused: %{id => PausedTask}`. Pause kills
the agent process but preserves worktree + Claude session name.
Resume dispatches into existing worktree with `--continue`.

## Test Policy

- Mirrored structure: `lib/factory/*.ex` → `test/factory/*_test.exs`
- Pure-function tests: `async: true` (completion, prompt, buffer)
- Integration tests: `async: false` (orchestrator, worktree)
- No mocking framework — behaviours + test adapters
