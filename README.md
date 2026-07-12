# Shep 🐕

[![quality](https://github.com/craigruks/shep/actions/workflows/quality.yml/badge.svg)](https://github.com/craigruks/shep/actions/workflows/quality.yml)

**You're the shepherd. Shep works the flock.**

Shep is an Elixir/OTP orchestrator that turns labeled GitHub issues into
CI-verified pull requests. It dispatches headless coding agents (Claude Code,
Codex) into isolated git worktrees, supervises each one to completion, and
steps tasks through a label state machine while you do something else
entirely.

You manage the *work*. Shep manages the *agents*.

![just shep demo: a task dispatched into an isolated worktree, agent output streamed, completion parsed](assets/demo.gif)

> [!TIP]
> **Just want it running?** → [Quickstart](#quickstart) ·
> **Want the philosophy?** → [Why](#why) ·
> **Want to talk to the dog?** → [Commands](#commands-speak-dog)

> [!IMPORTANT]
> **Reading this as an automated agent?** Start with [`AGENTS.md`](AGENTS.md).
> An agent reading the manual for the tool that dispatches agents. Sure. Why
> not. One rule: you may not create PRs yourself. Shep does that part.

## Why

Nobody wants to babysit a coding agent. Watching a terminal scroll is not
engineering. It's television with extra steps.

The fix is to move up one level: stop supervising *agents* and start managing
*work*. You triage issues, apply a label, and walk away. Shep polls the
tracker, claims the issue, cuts a worktree, briefs an agent, watches it work,
opens the PR, chases CI failures, and reports back. If an agent gets stuck,
Shep kills it and retries with backoff. If it stalls, you get a Slack ping,
not a frozen terminal.

The whistle is the label. The dog does the running.

## The first production run

Shep's first task after leaving home was deleting its own predecessor:
the in-repo orchestrator it was extracted from, still sitting in the
monorepo that raised it. Issue labeled `shep`, agent dispatched into an
isolated worktree, 74 files and 4,526 lines removed, PR opened, CI
watched to green. Label to PR: 7.5 minutes. Label to green CI: about
eleven.

The goal loop earned its keep on attempt one. The agent said done, but
the verify command came back red in the worktree, so Shep sent the
failure output back to the same session for a fix turn. No red commit
ever reached CI. That monorepo is private, so no link, but the receipts
are the point: this repo is not a mockup of an orchestrator, and its
first PR retired its ancestor.

## Lineage

Shep didn't come from nowhere. The story has a false start in it: the first
design was a TypeScript harness, a port of Matt Pocock's
[**Sandcastle**](https://github.com/mattpocock/sandcastle). Squint
at the module layout today (agent runner, stream buffer, prompt builder,
session, hooks) and you can still see Sandcastle's skeleton. The shape
survived. The language didn't.

Three things changed the build that spring:

- [**Stripe's minions**](https://stripe.dev/blog/minions-stripes-one-shot-end-to-end-coding-agents-part-2):
  isolated environments cheap enough that permission checks disappear and you
  fan out agents per task.
- [**strongDM's software factory**](https://factory.strongdm.ai/): where the
  "dark factory" name comes from, and the lesson that the hard part isn't
  generating code. It's designing verification you can trust with the lights
  off.
- [**Symphony**](https://github.com/openai/symphony): OpenAI's Codex
  orchestrator, open-sourced a week before Shep's first merge. The issue
  tracker as the control plane came from here. Symphony is Elixir/OTP, and
  Shep merged six days after theirs went public. The timing tells you most of
  the language story. (Independent implementation; no source copied.)

One deliberate deviation: the standard advice was "adopt Linear, run a
daemon." Shep skipped both. GitHub issues and labels are the *entire* state
machine, no new tools. No regrets so far.

The long version, with the receipts:
[**The factory runs dark**](https://www.layerkick.com/blog/dark-factory/).

### Why Elixir?

Because coding agents are a **process-management problem**, not an AI
problem. An agent session is a child process: it can succeed, hang, crash,
produce garbage, or quietly wander off-task while looking busy. Running
several at once means spawning, isolating, watching, killing, and retrying,
all without losing completed work. There's a platform whose founding premise
is "processes fail, so supervise them," and it isn't TypeScript. An agent is
just a Port under a Task.Supervisor; a crashed agent is a `:DOWN` message,
not a 2am incident. The orchestrator is an [error kernel](#ethos) that has
never met your bugs.

## How it works

```
  GitHub issue          Shep (OTP)                       GitHub PR
  ┌───────────┐   poll   ┌──────────────┐   worktree   ┌───────────┐
  │ label:    │ ───────► │ Orchestrator │ ───────────► │ [Shep] #42│
  │  "shep"   │          │  (GenServer) │   + agent    │ CI: watch │
  └───────────┘          └──────┬───────┘              └─────┬─────┘
        ▲                       │ supervise                  │
        │ labels move:          │ retry w/ backoff           │
        │ shep:in-progress      │ idle watchdog              │
        │ shep:in-review  ◄─────┴──── CI passed ◄────────────┘
        │ shep:failed     ◄────────── CI failed (fix turns + Slack)
```

One `Task.Supervisor` child per issue. Each agent gets:

1. **A claim.** The label flips to `shep:in-progress` so no one
   double-dispatches.
2. **A worktree.** A fresh branch `shep/<issue>` off your base branch, deps
   installed via your `on_worktree_ready` hook.
3. **A briefing.** A prompt template picked by issue type (`type:test-fix`,
   `type:lint-fix`, …) with `` !`shell` `` expansion and `{{VAR}}`
   substitution.
4. **A leash.** Idle watchdog, hard timeout, max turns. Line-buffered stdout
   streams back for liveness.
5. **A goal.** Not "the agent finished" but "a PR with green CI." After
   the agent signals `<completion>`, Shep runs your `goal.verify` command
   in the worktree; failures go back to the same session for a fix turn
   before any PR exists. Once the PR is up, red CI sends the failing
   check logs back to the session, the fix gets pushed, CI re-runs.
   Attempts are capped; exhaustion means `shep:failed`, a preserved
   worktree, and a Slack ping, never a silent shrug.

Supervision tree (the whole thing):

```
Shep.Application (one_for_one)
├── Registry            O(1) agent lookup
├── Shep.Config         WORKFLOW.md, hot-reloaded every 1s
├── Task.Supervisor     one child per running agent
└── Shep.Orchestrator   poll / dispatch / monitor / retry
```

## Quickstart

Prereqs: [mise](https://mise.jdx.dev) (installs Erlang, Elixir, `just`, `gh`,
and `jq` for you) and at least one agent CLI on PATH:
[`claude`](https://claude.com/claude-code) or
[`codex`](https://github.com/openai/codex). Run `gh auth login` once if you
haven't.

```sh
git clone git@github.com:craigruks/shep.git && cd shep
mise install          # erlang, elixir, just, gh, jq (mise.toml)
mix deps.get

# 1. Point Shep at your repo
$EDITOR WORKFLOW.md   # tracker.repo, workspace.root, hooks.on_worktree_ready

# 2. Create the labels Shep drives (once per repo)
for l in shep shep:in-progress shep:pr-created shep:in-review shep:failed \
         shep:promoted shep:no-merge shep:codex; do
  gh label create "$l" --repo you/your-repo 2>/dev/null || true
done

# 3. Label an issue "shep" and release the hound
just shep up          # or: just shep wake
just shep view        # tmux: orchestrator + a pane per task, auto-spawning
```

No repo handy? See the whole loop with a stub agent, zero setup:

```sh
just shep demo        # or, since this is a sheepdog: just shep trial
```

`WORKFLOW.md` is YAML front matter, hot-reloaded every second. Edit
concurrency, timeouts, or the tracker while Shep is running. No restarts.

> [!NOTE]
> The daemon pushes branches itself, and SSH agents (1Password, biometric)
> do not reach a nohup'd process. Give it non-interactive push auth once:
> `gh auth setup-git`, and if your remote uses SSH,
> `git config url."https://github.com/<you>/".insteadOf "git@github.com:<you>/"`.
> While you're in there, set the repo's `user.email` to your GitHub noreply
> address, or GH007 email privacy will reject the daemon's first push.

```yaml
tracker:   { kind: "github", repo: "you/your-repo" }
workspace: { root: ~/code/shep_worktrees }
agent:     { command: "claude", max_concurrent: 3, max_turns: 10 }
goal:      { verify: "mix quality", verify_fixes: 2, ci_fixes: 2 }
hooks:     { on_worktree_ready: "pnpm install --frozen-lockfile" }
staging:   { base_branch: "staging", pr_target: "staging" }
```

## Shepherding another repo

Shep cuts worktrees from `workspace.repo`, which does not have to be the
checkout Shep sits in. Point it at any local clone (bare repos work),
keep one config file per flock, and select it at startup:

```yaml
workspace: { root: ~/code/shep_worktrees, repo: /path/to/that/repo }
```

```sh
SHEP_WORKFLOW=.shep/WORKFLOW.thatrepo.md just shep up
```

One dog, many flocks. The tracked `WORKFLOW.md` stays a placeholder.

## Commands (speak dog)

One dispatcher: `just shep <command> [id]`. Every command has a proper name
and a herding name. They are the same command. Use whichever makes you
happier. We know which one that is.

| canonical | herding | what happens |
|---|---|---|
| `just shep demo` | `just shep trial` | full loop with a stub agent, zero setup |
| `just shep up` | `just shep wake` | start the orchestrator (background) |
| `just shep down` | `just shep rest` | stop it |
| `just shep run 42` | `just shep fetch 42` | dispatch an agent on issue 42 |
| `just shep queue` | `just shep pen` | list templates + queued candidates |
| `just shep ps` | `just shep flock` | status JSON: running, paused, totals |
| `just shep pause 42` | `just shep heel 42` | pause (worktree + session preserved) |
| `just shep resume 42` | `just shep send 42` | resume a paused task |
| `just shep attach 42` | `just shep take 42` | **you step in** (see below) |
| `just shep logs 42` | `just shep watch 42` | tail a task's raw stdout |
| `just shep session 42` | `just shep trail 42` | pretty-tail the agent's session |
| `just shep kill 42` | `just shep drop 42` | kill a stuck agent (no retry) |
| `just shep view` | `just shep field` | tmux: everything, live |
| `just shep promote` | `just shep home` | promote staging → main |

Plus the unglamorous ones: `start` (interactive iex), `triage`, `quality`,
`bootstrap <path>`, `help`.

### Taking over (`shep take`)

Sometimes the dog looks back at you. `just shep take 42` pauses the agent
(worktree and Claude session intact), drops **you** into the session
interactively, and when you exit, asks one question: *send Shep back out, or
keep it paused?* Pair-programming where your pair is a process you can
suspend. This is the entire human-intervention surface. Everything else is
labels and logs.

### The label state machine

| label | meaning |
|---|---|
| `shep` | queued; Shep may take it |
| `shep:in-progress` | claimed, agent running |
| `shep:pr-created` | branch pushed, PR open |
| `shep:in-review` | CI green; a human should look |
| `shep:failed` | goal not reached after capped fix attempts; reason posted as a comment |
| `shep:promoted` | shipped |
| `shep:codex` | route this issue to Codex instead of Claude |
| `shep:no-merge` | open the PR but skip CI-watch / auto-merge labels |

Dependencies work too: put `Depends on: #12, #45` in an issue body and Shep
won't dispatch it until those are `shep:in-review` or better.

## The three layers (running Shep with a handler)

At a sheepdog trial, the handler works the dog and the farmer owns the
flock. Same here, and each layer owns a different failure class:

| layer | role | owns |
|---|---|---|
| agents | do the work | wrong code (fix turns) |
| Shep | mechanical supervision | known failures: crash, stall, red CI |
| the handler | an agent session operating Shep | unknown failures: auth, config drift, new failure classes |
| you | intent and merge authority | judgment |

The handler is optional and event-driven, not a vigil. Routine runs need
no observer; Slack pings you on stall or failure. Sit a session down only
for first runs on a new repo or after config changes. Its prime
directive: every intervention ends as a commit (a code fix, a config
change, or a playbook line), so Shep's autonomy grows and the handler
gets quieter over time. The playbook lives in [`AGENTS.md`](AGENTS.md),
which is exactly the file an arriving agent reads first.

## Ethos

- **Error kernel.** The orchestrator never crashes from agent work. Every
  risky thing happens in a supervised Task; the GenServer just collects
  `:DOWN` messages and decides. Uptime is a design choice, not a hope.
- **The tracker is the database.** No Postgres, no Redis, no state file to
  corrupt. GitHub labels *are* the state machine; restart Shep and it
  re-learns the world from the tracker. (ETS holds a read-only snapshot for
  status: zero contention, zero persistence.)
- **Config is live.** `WORKFLOW.md` hot-reloads every second. Changing
  `max_concurrent` mid-run is editing a YAML value, not a deploy.
- **Failure is expected, so it's cheap.** Crashed agent → exponential backoff,
  3 attempts. Stalled agent → watchdog kill + Slack ping. Failed task → the
  worktree is *preserved* for post-mortem; successes are pruned.
- **No mocking framework.** Behaviours + test adapters (`Tracker.Memory`).
  111 tests, `mix quality` = format + credo --strict + test. Files < 300 lines.
- **Small enough to read.** ~3k lines of lib. You can read the whole thing
  with your coffee. That's not a limitation; that's the pitch.

## What Shep is not

- **Not a judge.** Verification is CI plus your review, not an LLM grading
  itself. The round-trip is mechanical on purpose.
- **Not magic.** An agent that can't fix your flaky test still can't fix
  your flaky test. Shep just finds out without you watching.
- **Not distributed.** One orchestrator, one machine, N agents.

## License

[MIT](LICENSE). Architecture influenced by OpenAI's
[Symphony](https://github.com/openai/symphony) (Apache-2.0) and Matt
Pocock's [Sandcastle](https://github.com/mattpocock/sandcastle). Independent
implementation, no source code copied. Credit where the ideas came from.

---

*Good dog.* 🐑
