# Installation

jx is distributed on Hex as `jido_orchestrator`. The package installs the `jx`
executable.

## Hex

Install the escript:

```bash
mix escript.install hex jido_orchestrator
```

Then run:

```bash
jx status
```

## Local Development

Install dependencies and run tests:

```bash
mix deps.get
mix test
```

Run the wrapper through Mix:

```bash
bin/jx status
```

## Build The Escript

Build a local escript:

```bash
mix escript.build
```

This creates a `jx` executable at the project root. To force the wrapper to use
the escript instead of `mix run`, set:

```bash
JX_USE_ESCRIPT=1 bin/jx sessions queues
```

## Database

By default, jx stores state in:

```text
~/.jx/jx.db
```

Override it for a single command:

```bash
jx --db /tmp/jx.db sessions queues
```

Or through the environment:

```bash
JX_DB=/tmp/jx.db jx sessions queues
```

## Required Runtime Tools

The local and SSH adapters expect standard command-line tools:

- `git`
- `tmux`
- `ssh` for remote hosts
- any configured agent binary, such as `codex`, `claude`, or `opencode`
- `acpx` when using `--transport acpx`

Use host doctor before assigning real work:

```bash
jx host doctor local --agent codex
jx host doctor local --agent codex --transport acpx
```
