# Agent Guidelines

## Workspace Overview

This workspace is the `jx` implementation, not `CLI-Tools`.

`jx` is the command-line entrypoint for Jido IDE, an Elixir-based orchestration
tool for durable SSH/tmux-backed work sessions and agent fanout workflows.

Development work in this workspace should stay rooted here:

```bash
/Users/developer/Documents/GitHub/workspaces/saysure
```

Do not redirect work into `CLI-Tools/`; that is a separate target workspace and
is not the implementation home for `jx`.

## Build & Test Commands

```bash
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix escript.build
```

For local dogfooding:

```bash
JX_USE_ESCRIPT=1 bin/jx --help
```

## Architecture Notes

`jx` is the control plane for orchestration. external target repositories

For fanout work:

- `jx` owns planning, preflight, launch eligibility, worktree setup, leases, and
  evidence aggregation.
- Agents own bounded domain execution inside `jx`-created worktrees.
- Append-only reports are execution-plane facts; mutable assignment records are
  control-plane state.

## Code Style

- Follow existing Elixir module and test patterns.
- Prefer small pure functions around filesystem and JSON boundaries.
- Keep orchestration safety decisions in `jx`, not in prompt-only agent
  instructions.
- Add focused ExUnit coverage for new command behavior and reducers.
