# Publishing

jx is published through two channels:

| Channel | Audience | Command |
|---|---|---|
| **Hex** | Elixir/OTP developers | `mix escript.install hex jido_orchestrator` |
| **GitHub Releases** | OTP release tarball | Download from release page |

The Hex package is published as `jido_orchestrator`. It installs the `jx`
executable and keeps the OTP app name as `:jx`.

## Build Docs Locally

Install dependencies:

```bash
mix deps.get
```

Generate docs:

```bash
mix docs
```

Open:

```text
doc/index.html
```

## Package Check

Before publishing:

```bash
mix hex.build
```

Then inspect the package contents carefully.

## Local Development Build

For local dogfooding, use the escript:

```bash
mix escript.build
./bin/jx version
```

## OTP Release

For environments with Erlang/OTP but without Elixir:

```bash
MIX_ENV=prod mix release
```

The release is placed at:

```text
_build/prod/rel/jx/
```

This is a standard Mix release that requires an Erlang/OTP runtime.

## Release Workflow

### 1. Tag a Release

```bash
git tag -a v0.0.1 -m "Release v0.0.1"
git push origin v0.0.1
```

### 2. CI Builds Everything

Pushing a `v*` tag triggers `.github/workflows/release.yml`:

1. Runs the full test suite (`mix test`)
2. Builds the Hex package (`mix hex.build`)
3. Builds the OTP release (`MIX_ENV=prod mix release`)
4. Creates a GitHub Release with `jido_orchestrator-*` release assets

The launcher bundle asset is named for the Hex package and contains the `jx`
executable, `version.txt`, and the `jx-release.tar.gz` sidecar used by the
launcher.

### 3. Publish Hex (Manual)

After the CI passes and the GitHub Release is created:

```bash
mix hex.publish
mix hex.publish docs
```

## Release Blockers

Do not publish to Hex or cut a release until these are resolved:

- [x] Confirm license and add a `LICENSE` file.
- [x] Confirm source repository URL for Hex links.
- [x] Confirm maintainers and organization ownership.
- [x] Confirm whether public docs should expose all internal modules or hide schemas. *(Decision: keep current `groups_for_modules` structure. Public API boundary is `JX` and `JX.Workspace`; internal modules are grouped by function and documented for advanced users.)*
- [x] Run the full test suite for the release candidate.
- [x] Run `mix docs` and treat warnings as release blockers.
- [x] Run `mix hex.build` and inspect package contents.
- [x] Build `MIX_ENV=prod mix release` and verify the OTP release works.

## Known Limitations

- **Upstream warnings in `:prod`**: Some dependencies emit compiler warnings in `MIX_ENV=prod`. These do not affect functionality. The `mix precommit` alias and CI test job run in `:test`, so they are unaffected. Release builds intentionally do not use `--warnings-as-errors`.

## Publish Commands

Only after explicit approval:

```bash
mix hex.publish
```

Docs can also be published with:

```bash
mix hex.publish docs
```

Publishing is a public release action and should stay held until the lead agent confirms the release boundary.
