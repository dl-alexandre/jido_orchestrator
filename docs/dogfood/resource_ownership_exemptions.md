# Resource Ownership Exemptions

Long-lived resources must be registered in `JX.ResourceOwnerships`.

Short-lived probes are exempt only when they self-clean inline or create no
durable resource. These exemptions are intentionally searchable and mirrored by
`jx cleanup audit`.

## Exemptions

### `JX.HostDoctor.tmux_checks/1`

- Resource type: `tmux_session`
- Policy: `self_cleaning_probe`
- Reason: creates a temporary doctor session with an EXIT trap and an explicit
  `kill-session` before the script exits.

### `JX.HostDoctor.workspace_checks/1`

- Resource type: `temp_path`
- Policy: `self_cleaning_probe`
- Reason: creates and deletes a temporary file inline as part of the host check.

### `JX.PaneTransport.probe/2`

- Resource type: `command_probe`
- Policy: `no_resource_created`
- Reason: sends a read-only probe through an already-open pane and does not
  create a long-lived resource.
