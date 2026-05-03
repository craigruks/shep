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

## Test Policy

- Mirrored structure: `lib/factory/*.ex` → `test/factory/*_test.exs`
- Pure-function tests: `async: true` (completion, prompt, buffer)
- Integration tests: `async: false` (orchestrator, worktree)
- No mocking framework — behaviours + test adapters
