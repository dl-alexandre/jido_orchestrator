# Call Handoffs

Call handoffs are durable notes from synchronous surfaces such as phone calls,
meetings, talks, or foreground chats.

The goal is not to record a transcript forever. The goal is to turn a live
decision into structured orchestration state.

## Create A Handoff

```bash
jx call handoff add \
  --surface chat \
  --project saysure \
  --title "Secondary docs handoff" \
  --summary "HexDocs guide set added; publish still held for license and final package name." \
  --follow-up "Primary should refresh CI and resolve delegation review."
```

## List Handoffs

```bash
jx call handoff ls --status open --json
```

## Apply A Handoff

Handoffs can be applied as:

- a chambered prompt
- a watch
- a held profile
- a record-only decision

The exact action should match the risk level. A call note should not silently
override a protected session or destructive policy boundary.

## Voice And Meet Surfaces

Voice and meeting integrations feed this same model. The bundled Google Meet
participant plugin records `meet` handoffs automatically when sessions are
created or recovered:

1. Summarize the decision.
2. Attach project/ref context.
3. Record follow-up.
4. Apply as prompt, watch, or hold.
5. Let the daemon observe and continue.

See `google_meet.md` for personal auth, Chrome recovery, Twilio realtime, and
artifact export commands.
