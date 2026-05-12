# jido_orchestrator

`jido_orchestrator` is the Hex package for `jx`: a terminal control plane for
durable agent orchestration.

`jx` keeps agent work visible and recoverable when it spans tmux panes, SSH
sessions, local repositories, CI runs, approvals, and long-running foreground or
background agents. It does not replace Codex, Claude, or opencode. It gives an
operator or lead agent a durable record of what exists, what changed, what is
blocked, and which actions are safe to take next.

## Install From Hex

```bash
mix escript.install hex jido_orchestrator
```

That installs the `jx` executable:

```bash
jx --help
```

GitHub release bundles are also available at:

```text
https://github.com/dl-alexandre/jido_orchestrator/releases
```

## Why Use It

Agent work gets hard to operate when the useful state is spread across terminal
scrollback, remote panes, local branches, CI pages, and chat messages. `jx`
turns that state into durable records and command surfaces.

Use `jx` when you need to:

- keep many agent sessions observable without manually polling every pane
- launch or resume bounded work against registered projects
- track session profiles, queues, watches, handoffs, and CI state
- require explicit approval before risky or public actions
- preserve audit evidence for what an orchestrator saw and decided

## What It Stores

`jx` persists the operational state around agent execution:

- hosts, projects, tasks, and worktrees
- tmux session metadata and terminal observations
- session profiles, controls, watches, and queues
- CI watches, handoffs, notifications, and wake triggers
- approval records, safe actions, leases, assignments, and timelines
- orchestrator heartbeats and audit evidence

The durable record is the point. A session can move, block, finish, or need new
input, and `jx` can still compare the latest observation against the saved
objective before deciding what to surface or execute.

## Quick Start

Initialize local state and register a host:

```bash
jx init
jx host add local --local --workspace /tmp/jx
jx host doctor local --agent codex
```

Register a project and assign bounded work:

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

Run the orchestrator in dry-run mode before allowing it to act:

```bash
jx orchestrator start --dry-run --replace
jx orchestrator health --json
jx orchestrator heartbeats --json
```

## Core Commands

- `jx tui` gives a compact terminal dashboard for the current work board.
- `jx sessions` discovers tmux, SSH, and process-backed sessions.
- `jx sessions queues` groups actionable session work.
- `jx project brief <project>` narrows orchestration context to one project.
- `jx assign <project> <prompt>` launches a durable agent-backed task.
- `jx fanout plan` prepares multi-assignment work packets.
- `jx ci watch` records durable GitHub PR check watches.
- `jx actions` and `jx approvals` expose policy-gated execution.
- `jx timeline <scope> <id>` reconstructs audit history from durable events.

## HexDocs

HexDocs are configured through ExDoc and are the canonical long-form reference:

```text
https://hexdocs.pm/jido_orchestrator
```

The published docs use `docs/hexdocs/overview.md` as the main page. The source
pages live under `docs/hexdocs/` and are grouped from `mix.exs`.

Generate the docs locally with:

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

## Naming Contract

- Hex package: `jido_orchestrator`
- Installed executable: `jx`
- OTP app: `:jx`
- Elixir modules: `JX.*`
- GitHub repository: `dl-alexandre/jido_orchestrator`

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
