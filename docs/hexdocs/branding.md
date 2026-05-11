# Branding Boundary

The public identity is:

- CLI: `jx`
- product: `jx`
- tagline: durable agent orchestration from the terminal

The implementation uses:

- OTP app: `:jx`
- modules: `JX.*`
- primary CLI: `jx`

## Why This Boundary

`jx` is short, scriptable, and visually distinct from generic agent commands.
It also describes the actual user surface better than an IDE name: terminal
operations for sessions, watches, queues, handoffs, and policy-gated actions.

## Current State

Current state:

- HexDocs use jx as the public name.
- `bin/jx` is the local wrapper.
- `mix escript.build` emits `jx`.
- `JX.*` is the stable module namespace.
- runtime defaults use `~/.jx`.
