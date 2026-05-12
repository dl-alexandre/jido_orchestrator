# jido_orchestrator

`jido_orchestrator` is the Hex package for `jx`, a terminal control plane for
durable agent coding sessions.

`jx` coordinates work that is already happening across tmux panes, SSH sessions,
local repositories, CI watches, approvals, and long-running agent processes. It
is not a replacement for Codex, Claude, or opencode. It is the layer that helps
an operator or foreground agent keep many concurrent coding sessions observable,
recoverable, and policy-gated.

## Install

Install from Hex:

```bash
mix escript.install hex jido_orchestrator
```

This installs the `jx` executable:

```bash
jx status
```

GitHub release bundles are also available at:

```text
https://github.com/dl-alexandre/jido_orchestrator/releases
```

## What It Manages

`jx` persists the operational state around agent work:

- hosts, projects, tasks, and worktrees
- tmux session metadata and terminal observations
- session profiles, controls, watches, and queues
- CI watches, handoffs, notifications, and wake triggers
- approval records, safe actions, leases, assignments, and timelines
- orchestrator heartbeats and audit evidence

The durable record is the point. A session can move, block, finish, or need a
new prompt, and `jx` can still compare the latest observation against the saved
objective and decide what is safe to do next.

## Quick Start

Register a local workspace and check host readiness:

```bash
jx init
jx host add local --local --workspace /tmp/jx
jx host doctor local --agent codex
```

Register a project and assign work:

```bash
jx project add my-app --host local --repo /path/to/my-app
jx assign my-app "Investigate the failing import flow" --agent codex
```

Inspect active work:

```bash
jx tui
jx sessions queues --json
jx project brief my-app --json
```

Run the background orchestrator in dry-run mode:

```bash
jx orchestrator start --dry-run --replace
jx orchestrator health --json
jx orchestrator heartbeats --json
```

## Common Surfaces

- `jx tui` gives a compact terminal dashboard for the current work board.
- `jx sessions` discovers tmux, SSH, and process-backed sessions.
- `jx sessions queues` groups actionable session work.
- `jx project brief <project>` narrows orchestration context to one project.
- `jx assign <project> <prompt>` launches a durable agent-backed task.
- `jx fanout plan` prepares multi-assignment work packets.
- `jx ci watch` records durable GitHub PR check watches.
- `jx actions` and `jx approvals` expose policy-gated execution.
- `jx timeline <scope> <id>` reconstructs audit history from durable events.

## Documentation

HexDocs are configured through ExDoc and are the canonical long-form reference:

```text
https://hexdocs.pm/jido_orchestrator
```

The source pages live in `docs/hexdocs/` and are grouped from `mix.exs`.
Generate them locally with:

```bash
mix deps.get
mix docs
```

Useful entry points:

- Overview: `docs/hexdocs/overview.md`
- Installation: `docs/hexdocs/installation.md`
- CLI reference: `docs/hexdocs/cli.md`
- Orchestration model: `docs/hexdocs/orchestration.md`
- Safety policy: `docs/hexdocs/safety_policy.md`
- Publishing: `docs/hexdocs/publishing.md`

## Runtime Requirements

The local and SSH adapters expect standard command-line tools:

- `git`
- `tmux`
- `ssh` for remote hosts
- an agent binary such as `codex`, `claude`, or `opencode`
- `acpx` when using `--transport acpx`

By default, `jx` stores local state under `~/.jx`. Override the database with
`--db path/to/jx.db` or `JX_DB=path/to/jx.db`.

## Development

Run the main checks:

```bash
mix deps.get
mix hex.audit
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix docs
mix hex.build
mix precommit
```

Build the local escript:

```bash
mix escript.build
JX_USE_ESCRIPT=1 bin/jx status
```

Build the Rust launcher:

```bash
cargo fmt --manifest-path crates/jx-launcher/Cargo.toml -- --check
cargo build --manifest-path crates/jx-launcher/Cargo.toml --release --locked
```

The OTP app and module namespace remain `:jx` and `JX.*`. The Hex package and
repository are named `jido_orchestrator`; the installed command is `jx`.
