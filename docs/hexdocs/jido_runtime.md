# Jido Runtime

Jido is wired as a thin supervised runtime layer around Workspace operations.

The important rule:

> Jido actions delegate to `JX.Workspace`; they do not bypass policy.

## Why Jido Is Here

Jido gives the project a uniform action surface for agents and future
asynchronous workers.

It is useful for:

- wrapping Workspace calls as validated actions
- composing safe orchestration steps
- exposing compact tools to other agents
- keeping action results structured
- supporting future background workers

## What It Should Not Do

Jido should not become a second implementation of:

- SSH policy
- tmux policy
- Git write rules
- session safety checks
- profile comparison logic

Those belong in `JX.Workspace` and the domain modules it delegates
to.

## Current Runtime

`JX.Jido` starts under the application supervisor and uses:

```elixir
use Jido, otp_app: :jx
```

Jido action modules live under:

```text
lib/jx/jido/actions/
```

The implementation names are:

- app: `:jx`
- modules: `JX.*`
