# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`jx` (Hex package `jido_orchestrator`) is a durable terminal control plane for agent
orchestration. It is an escript/CLI plus an OTP application — not a Phoenix web app.
It persists hosts, projects, tasks, worktrees, sessions, observations, approvals,
and orchestrator state to a local SQLite database so agent work spread across tmux,
SSH, branches, and CI has one operational record.

Toolchain is pinned in `.tool-versions`: Erlang/OTP 28.4.2, Elixir 1.19.5.

## Commands

```bash
mix deps.get
mix compile --warnings-as-errors   # CI treats warnings as errors
mix test                           # full suite
mix test test/jx/cli_test.exs      # single file
mix test test/jx/cli_test.exs:42   # single test by line
mix format --check-formatted
mix precommit                      # compile (warnings-as-errors) + format check + test
mix jx.contract                    # contract tests only (dev_ide + safe_actions registry)
mix docs                           # build HexDocs
mix escript.build                  # build the `jx` escript locally
```

CI (`.github/workflows/ci.yml`) runs: `hex.audit`, format check, warnings-as-errors
compile, `mix test`, `mix docs`, `mix hex.build`, then `mix precommit`. Match all of
these before pushing.

## Architecture

### The Workspace policy boundary

`JX.Workspace` (`lib/jx/workspace.ex`) is the single orchestration API shared by the
CLI, the daemon, and Jido actions. It is the **policy boundary**: safety checks,
coordination of task records, worktrees, tmux panes, profiles, CI watches,
delegations, handoffs, and heartbeats all route through it. Lower-level modules
under `lib/jx/<domain>/` provide storage (Ecto schemas) and transport details, but
callers should add a small `Workspace` function rather than bypassing policy in a
schema or transport module. Workspace functions return plain maps and tagged tuples
because consumers need stable JSON-like packets.

### Three layers, three entrypoints — one source of truth

The same durable records are observed and mutated by:
- **CLI** — `JX.CLI` (`lib/jx_cli/cli.ex`) dispatches to per-command modules in
  `lib/jx_cli/cli/` (e.g. `host.ex`, `project.ex`, `session.ex`, `orchestrate.ex`).
  This is the escript `main_module`.
- **Daemon** — `JX.OrchestratorDaemon` / `JX.OrchestratorRuntime`, the autonomous
  orchestration loop.
- **Jido actions** — `JX.Jido` is a thin Jido runtime (`use Jido, otp_app: :jx`).
  Jido actions are *adapters over the Workspace API*, not a parallel business layer.

`JX.Application` supervises `JX.Repo`, `JX.Jido`, `JX.OrchestratorRuntime`, and
`JX.HostCapacity.CapacityPoller`. When run as a Burrito-wrapped standalone binary,
the app boots and then dispatches `JX.CLI.main/1`.

### Safety model

Observation is separated from execution. Inspection, queueing, profile updates, and
dry-run planning are low-risk. Destructive, public, ambiguous, or externally visible
actions are gated behind approvals and `JX.OperationPolicy` / `JX.SafeActions`.
Invariants: SSH is transport not identity; one task → one isolated workspace/session;
append-only evidence preferred over mutable state; adapters stay replaceable; safety
is enforced in code and policy, not prompt convention.

### Persistence

SQLite via `ecto_sqlite3`. Repo is `JX.Repo`, DB path defaults to `~/.jx/jx.db`
(override with `JX_DB`). Migrations live in `priv/repo/migrations/`; `JX.Migrations`
is the runtime migration helper invoked by the CLI (`jx init`), with a file-based
migration lock. Each `lib/jx/<domain>.ex` is a context module with a matching
`lib/jx/<domain>/` directory holding its Ecto schemas.

### Other notable pieces

- `Mix.Tasks.Compile.StaleBeamCleaner` (in `mix.exs`) is a custom compiler prepended
  to `Mix.compilers()` that deletes stale numbered `.beam` files before compilation.
- `crates/jx-launcher/` is a Rust launcher binary.
- `scripts/` + `bin/` contain Google Meet audio/chat bridge scripts (shell + Swift)
  used by the `JX.GoogleMeet` / participant-plugin surfaces.
- Agent/runner commands (`claude`, `codex`, `opencode`, `acpx`) are configured in
  `config/config.exs` and overridable via `JX_*_BIN` / `JX_*_CMD` env vars.
- `config :jx, :planner_playbooks` lists `JX.OrchestratorPlanner.Playbook` modules;
  `ExamplePlaybook` is a project-specific default meant to be replaced when adopting
  jx elsewhere.

## Conventions

- Public API surface is `JX` and `JX.Workspace`; `test/jx/public_boundaries_test.exs`
  guards the boundary — keep new cross-cutting behavior behind `Workspace`.
- HexDocs under `docs/hexdocs/` are the canonical long-form reference and are grouped
  in `mix.exs` `docs/0`; update them when behavior changes.
