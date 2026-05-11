# CI Watches

CI watches track GitHub pull request checks and convert results into durable
orchestration work.

## Digest

Read a PR's current checks:

```bash
jx ci digest 461 --repo acme-corp/example-project --json
```

The digest groups checks into:

- pass
- fail
- pending
- skipped
- cancelled

It also classifies common failures such as Credo, test failures, and coverage
issues when logs are available.

## Watch

A CI watch stores a PR goal and a prompt policy:

- `notify` records a notification.
- `prompt` chambers a follow-up prompt.
- `hold` blocks the profile for review.

## Review

Review a watch:

```bash
jx watch review wat-abc123def0 --json
```

GitHub PR CI watches record the PR head SHA when the watch is first reviewed, or
you can pin it explicitly with `--head-sha`. Later reviews compare the live PR
head to the watched head and mark stale watches `superseded` instead of acting
on old CI results.
