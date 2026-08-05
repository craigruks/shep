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
just shep build           #          build the mix release → bin/shep (run once, and after code changes)
just shep smoke           # sniff:   boot the built binary, assert supervision tree is alive (hermetic)
just shep up              # wake:    start daemon via bin/shep (background, idempotent)
just shep down            # rest:    stop daemon gracefully (bin/shep stop)
just shep restart         #          restart daemon in place (bin/shep restart)
just shep console         # whistle: live IEx into the running flock (bin/shep remote)
just shep run <issue>     # fetch:   dispatch an agent on one issue
just shep queue           # pen:     list templates + queued candidates
just shep ps              # flock:   status JSON: running, paused, claimed
just shep pause <id>      # heel:    pause task (preserves worktree + session)
just shep resume <id>     # send:    resume paused task (--continue)
just shep attach <id>     # take:    shepherd steps in: pause → Claude → offer resume
just shep logs <id>       # watch:   tail a task's raw stdout
just shep session <issue> # trail:   pretty-tail the agent's Claude session
just shep kill <id>       # drop:    kill a stuck agent (no retry, worktree kept)
just shep tidy            # muck:    reclaim workspaces no live task owns
just shep view            # field:   tmux: orchestrator + auto-spawning task panes
just shep promote         # home:    open the staging→main promotion PR
just shep help            #           full command table
```

`attach`/`take` is the human-takeover surface (formerly "foreman"):
the shepherd steps onto the field, works the session interactively,
then sends Shep back out.

The daemon is a `mix release`: `just shep build` produces `bin/shep`, and
the lifecycle recipes drive it (`bin/shep start|stop|restart|pid|remote`).
`up` backgrounds `bin/shep start` (logs still land in
`.shep/orchestrator.log`, appended — a restart continues the file
instead of destroying the record of why the last run failed; each boot
opens with a `=== shep <version> up | pid … | workflow …` banner, and
the file shifts down to `.log.1`/`.log.2` only once it passes 8 MiB);
`down` is a graceful `bin/shep stop`
(`:init.stop` drains the supervision tree — no more `kill -9` orphaning
agent Ports or leaving worktree locks). The same tarball ships ERTS, so it
runs with no Elixir installed; a `v*` tag push publishes per-platform
tarballs to the GitHub release (`.github/workflows/release.yml`).

Control commands reach a running daemon over distributed Erlang (node
`shep@<host>`, started by `just shep up`). With no daemon they fall back
to a local one-shot node. `just shep demo` runs the whole loop with a
stub agent and a memory tracker; nothing is pushed.

## Branch flow

Two branches, one human gate.

- **`staging` is the integration branch.** Dogfood and feature PRs target
  `staging` (the flock config's `pr_target`). Green PRs merge here; this
  half runs without a human.
- **`main` is release-only.** It takes no direct pushes. It advances only
  through a *promotion PR* from `staging` that a human reviews and merges.
  That merge is the single human gate in the pipeline.
- **The promotion PR merges with a merge commit (`--no-ff`), never
  squash** — so staging's history stays connected to `main` and promotion
  PR bodies never re-list already-promoted commits. Feature PRs into
  `staging` still squash. A `promotion-guard` workflow on `main` fails the
  build if the tip advanced via a non-merge commit.
- **Both branches** require `quality` + `release-smoke` green before a
  merge (branch rulesets), so a change that breaks the release cannot land.
- **Releases:** bump the version on `staging`, open the promotion PR, tag
  `vX.Y.Z` on `main` after it merges. The tag push builds the smoke-gated
  tarballs.

The automation opens the promotion PR and stops; reading and merging it is
the human's job. GitHub blocks self-approval, so on a solo repo this gate
is convention plus the rule that `main` accepts no direct pushes.

## Agent Selection

`agent.model` in WORKFLOW.md picks the default Claude model (default
"opus", the latest Opus alias; pin an exact id to freeze it).
Hot-reloaded like all config.
A `shep:model:<name>` label on an issue overrides it for that issue
alone (`shep:model:sonnet`, `shep:model:claude-opus-5-20251101`) — the
override rides the task through fix turns and resumes, and `just shep ps`
reports the model each running task is on. Values that aren't plausible
model names are logged and ignored, falling back to `agent.model`.
`shep:codex` label on GitHub issue → Codex CLI instead of Claude.
Codex honours `shep:model:` too, but never inherits `agent.model`
(that names a Claude model); an un-overridden Codex task runs on the
Codex CLI's own default.

## Execution Location

Orthogonal to *what* runs: *where* it runs. `agent.location` picks the
fleet default (`local`, the git worktree); a `shep:sandbox` label runs
that issue in a Vercel sandbox instead — provisioned from
`sandbox.snapshot`, cloned over https with a token from
`sandbox.github_token_command`. `Shep.Workspace` is the whole boundary:
prepare, run the agent, run a shell command, run git, clean up.
`Shep.AgentRunner.Exec` is location-blind, because `sandbox exec` streams
line by line and propagates exit codes — a remote turn is the same Port
with a different command.

A sandbox is metered, so nothing keeps one alive by default. Success
removes it; failure pushes the task branch first so the agent's commits
survive, then removes it (`sandbox.keep_on_failure` holds it open for
live debugging). Drain, watchdog kill, total timeout, and `just shep
kill` all release it too, since the runner's own cleanup dies with the
process — and a boot sweep reaps what a crash left behind.

`shep:codex` + `shep:sandbox` is rejected up front: no Codex credential
is forwarded, so it would 401 remotely. The snapshot carries no Elixir,
so this repo's own `goal.verify` cannot run in a sandbox yet.
Agent-specific modules: `AgentRunner.Claude`, `AgentRunner.Codex`.
Claude sessions use `--name "shep-{id}"` for persistence.

## Tidy

A worktree outlives its run three ways: the task was interrupted (the
runner's cleanup dies with the process), it failed and was preserved for
post-mortem, or it was dirty and `Worktree.remove` refused. Boot only
prunes registrations for directories already gone, so the rest piled up
until someone noticed them in a UI.

`Shep.Tidy` reclaims them. `just shep tidy [--dry-run]` runs a pass by
hand; set `workspace.tidy_interval_ms` to have the daemon sweep on a
timer (shipped default `0`, off — an unattended deleter is opt-in). The
sweep runs in a supervised Task, never inline, since it touches git and
the network.

The rule is deliberately not "the issue looks finished": a label says
what a tracker believes, not whether this directory holds the only copy
of something. A worktree goes only when no task is running or paused in
it, the tree is clean, and its HEAD is contained in some remote branch —
pushed or merged, and it belongs to this clone (flocks can share a
worktree root). Decided from git alone. Everything else is reported and
left. Note "clean" is git's definition: ignored files do not count, so a
worktree holding only a hook-written `.env` is reclaimed. The same pass runs `Sandbox.sweep/2`, so both kinds of
workspace are covered by one job.

## Pause/Resume

Orchestrator tracks `paused: %{id => PausedTask}`. Pause kills
the agent process but preserves worktree + Claude session name.
Resume dispatches into existing worktree with `--continue`.

## Test Policy (two levels)

Level 1, granularity: every source file with behavior has a mirrored
test file (`lib/shep/x.ex` → `test/shep/x_test.exs`), the Elixir
stand-in for colocated tests. Module tests live in their own mirror,
not in a neighbor file. Exempt classes: mix task wrappers (thin shells
over tested modules), `application.ex` (OTP boilerplate), `types.ex`
(bare structs), `shep.ex` (moduledoc), and the dev-only credo checks.

Level 2, confidence (after Kent C. Dodds' [Testing Trophy](https://kentcdodds.com/blog/the-testing-trophy-and-testing-classifications)):
write tests, not too many, mostly integration. Static analysis is the
base of the trophy (format, credo --strict, dialyzer). Pure functions get direct units. Side-effecting
code is tested through real collaborators: real git repos and bare
remotes, shell scripts as stand-in agents, with test adapters only at
the network boundary (gh, CI verdicts, tracker). No mocking framework,
ever; behaviours plus adapters (`Tracker.Memory`, `CIWatchStub`,
`:gh_runner`).

Deliberate deviations, documented rather than hidden: private loops
are exposed via `*_for_test` wrappers because the front door (run/3)
drags Ports, worktrees, and PRs along; the automated suite stops at
integration, and the e2e tier is `just shep demo` plus live dogfood
runs.

Mechanics: pure-function tests are `async: true`; anything installing
an app-env adapter is `async: false` and cleans up in `on_exit`.

## Operating Shep as an outer agent (the handler)

Shep supervises known failure modes (crash, stall, red CI). A Claude
session operating Shep owns the unknown ones: auth, config drift, new
failure classes. Day to day: routine runs need no observer (Slack pings
on stall/failure); sit resident only for first runs on a new repo or
after config changes.

Playbook:

- Start: `just shep build` once (and after any code change — `up` runs the
  compiled release, not source), then `SHEP_WORKFLOW=<path> just shep up`,
  then monitor
  `.shep/orchestrator.log` with a FILTERED tail (verdict lines, not
  per-poll noise). The file spans sessions —
  `grep '=== shep' .shep/orchestrator.log` lists the boot boundaries, so
  the evidence of the run you just restarted away from is still there. That one tail now covers both milestones and
  liveness: each dispatch logs the phase contract, and a quiet agent
  emits gap-triggered "task N alive: agent quiet …" heartbeats every
  ~30s. A separate external stall detector on the runs log is no longer
  required — silence of BOTH milestones and heartbeats is the alarm,
  and the recurring watchdog has already killed a truly-dead task.
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
