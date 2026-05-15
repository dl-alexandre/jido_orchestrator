# #10 — Profile upsert: documented closure (no code change)

The original `/phx:perf` finding #10 grouped three "get-then-insert_or_update"
sites under "classic upsert pattern":

1. `JX.Projects.upsert_project/1`
2. `JX.SessionProfiles.upsert_session_profile/2`
3. `JX.SessionProfiles.upsert_operator_profile/2`

The first one was safe to collapse to `Repo.insert` with `on_conflict`
because its single caller (`JX.Workspace.add_project`) always provides the
full required attribute set — closed in commit `64d54c4`.

This doc records why the **other two** are **not** going to follow the same
path. The Ecto agent's recommendation was an over-fit to a generic pattern;
the actual semantics of these functions require the existing structure.

## What the profile upserts actually do

Both `upsert_session_profile/2` and `upsert_operator_profile/2` exist to
**partial-merge** an attribute map onto an existing profile (or insert it
if not present). Callers pass *only the fields they want to change* — a
TUI tweaks `:next_prompt`, a CLI command updates `:risk_level`, a
reconciler sets `:lifecycle_status`, etc.

The current shape preserves that:

```elixir
profile = Repo.get_by(SessionProfile, ref: ref) || %SessionProfile{ref: ref}

profile
|> SessionProfile.changeset(attrs)        # cast merges attrs onto loaded fields
|> Repo.insert_or_update()                 # 1 write
```

For the **update** path, the changeset starts from the loaded struct, so
`validate_required([:ref, :prompt_status])` succeeds via the *existing*
values even when `attrs` doesn't contain them.

## Why naive `on_conflict` breaks the semantics

A literal application of the agent's pattern would look like:

```elixir
%SessionProfile{ref: ref}
|> SessionProfile.changeset(attrs)
|> Repo.insert(
  on_conflict: {:replace_all_except, [:id, :inserted_at]},
  conflict_target: [:ref]
)
```

Two failure modes:

1. **`validate_required` fails on the fresh struct** when `attrs` does not
   include `:prompt_status` (or any other required field). The fresh
   `%SessionProfile{ref: ref}` has `prompt_status = nil`, the changeset
   doesn't see it in attrs, and `validate_required` rejects the changeset
   before `Repo.insert` is even called.

2. **Even if validation passed**, `:replace_all_except` would overwrite
   *every* column on the existing row with the values from the fresh
   struct (mostly `nil` / schema defaults). The whole point of the
   partial-merge — "leave the other fields alone" — is gone. This is
   silent data loss.

A field-list-from-attrs variant (`on_conflict: {:replace, Map.keys(attrs)}`)
fixes #2 but not #1. To fix #1 you'd need to skip `validate_required` on
the conflict path, which Ecto doesn't support — validations run on the
changeset, not on the eventual SQL outcome.

## The implicit query-count math

The agent framed this as "halves DB round-trips." It does not. For the
profile case:

- Current: `Repo.get_by` (1 read) + `Repo.insert_or_update` (1 write) = **2**
- Naive `on_conflict`: would be 1, but breaks semantics → not a valid option
- Smart `on_conflict` with a loaded struct: still requires the `get_by` to
  build a correct merge → **2**

There is no path to 1 round-trip that preserves partial-merge semantics.
The "saved" round-trip the agent counted only exists in the
full-attribute-rewrite shape, which is what `upsert_project` does.

## Decision

**Leave `upsert_session_profile/2` and `upsert_operator_profile/2`
unchanged.** Their current implementation is the right pattern for what
they do. The /phx:perf finding #10 is closed: one site fixed (project),
two sites verified as correctly shaped (profiles).

Same shape of investigation as `/phx:perf` finding #3, which was also
based on a misread of the underlying semantic (state-change log vs.
simple dedup). Both were caught by reading the call sites and the
changeset rather than applying the pattern directly.

## Related

- Commit `64d54c4` — the project half of #10
- `docs/perf/monitor_events_dedup_scope.md` — same investigation
  discipline applied to #3
