# Dogfood Friction Log

## 2026-05-12

### Issue

DevIDE/Fleet dogfood and test flows leaked 49 tmux sessions.

### Impact

The operator had to manually inspect `tmux list-sessions`, map panes back to
DevIDE temp directories, verify the sessions were idle, and clean them up by
name. The resources were project-created but not attributable from JX state.

### Expected

Every project-created tmux session and temp resource should have durable
ownership metadata, be inspectable by a cleanup dry-run, and expose the exact
cleanup command before anything destructive is allowed.

### Evidence

- Session names: `devide_*`, `test-*`
- Root path: `/Users/developer/Documents/GitHub/workspaces/milc/dev/dev_ide/tmp/...`
- Observed count: 41 `devide_*` sessions and 8 `test-*` sessions
- Panes were idle shells after the controller and runner processes had exited.

### Fix Class

Lifecycle ownership / cleanup

### Priority

P0
