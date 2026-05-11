# Google Meet Participant Plugin

Google Meet is bundled as a participant plugin for synchronous orchestration
surfaces. It stores personal Google OAuth profiles, durable Meet sessions,
browser-agent/Chrome recovery targets, optional Twilio Media Stream plans, and
artifact exports.

The Meet REST API is used for spaces, conference records, participants,
recordings, transcripts, and smart notes. Joining or recovering a live
participant is handled through Chrome remote debugging targets because Meet does
not expose a REST join endpoint.

## Personal Auth

```bash
jx meet auth configure \
  --profile personal \
  --client-id "$GOOGLE_OAUTH_CLIENT_ID" \
  --client-secret-env GOOGLE_OAUTH_CLIENT_SECRET \
  --redirect-uri http://127.0.0.1:8765/oauth2/callback \
  --artifacts

jx meet auth url --profile personal
jx meet auth exchange --profile personal --code <code>
jx meet auth status --json
```

Use the narrow default Meet scopes unless artifact downloads require the
restricted Drive-backed Meet artifact scope.

## Sessions

```bash
jx meet session create \
  --meeting https://meet.google.com/abc-mnop-xyz \
  --auth-profile personal \
  --chrome-node http://127.0.0.1:9222 \
  --paired-chrome-node http://127.0.0.1:9223 \
  --twilio-stream-url wss://voice.example.com/meet \
  --twilio-mode start

jx meet session plan met-abc123def0 --json
jx meet session join met-abc123def0 \
  --runner browser-agent \
  --browser-agent-command "$JX_MEET_BROWSER_AGENT_CMD"
jx meet session ls --status recovered
```

Session creation defaults to creating a `meet` call handoff so the meeting is
visible in call briefs and orchestration queues.

The default join runner is `browser-agent`: `jx` sends the session and a
join task to a configured browser-agent command, then stores the returned tab,
status, and action trace. Use `--runner chrome-cdp` when you want the built-in
Chrome remote-debugging fallback.

## Realtime Voice Loop

Google Meet sessions can now plan the realtime voice loop that OpenClaw-style
participants need:

```bash
jx meet realtime plan met-abc123def0 --provider browser-agent --json
jx meet realtime start met-abc123def0 \
  --provider browser-agent \
  --live \
  --approve-audio-capture \
  --approve-speech-output \
  --approve-notes-or-transcription \
  --json
jx meet realtime watch met-abc123def0 \
  --browser-agent-command "$JX_MEET_BROWSER_REALTIME_CMD" \
  --consult-command "$JX_MEET_CONSULT_CMD" \
  --speak \
  --speech-output-command "$JX_MEET_BROWSER_SPEECH_OUT_CMD" \
  --iterations 0
jx meet realtime watch met-abc123def0 \
  --chat-file tmp/meet-chat-input.txt \
  --speak \
  --speech-output-command scripts/meet_chat_output_queue.sh \
  --iterations 0
jx meet realtime consult met-abc123def0 \
  --transcript "We decided to wait for CI and review blockers." \
  --decision "wait for CI" \
  --follow-up "review blockers"
```

The default provider and bridge are browser-agent based. If the session was
joined or recovered through a browser-agent tab, the bridge can plan against
that active tab. External browser agents can also be supplied through
`--browser-agent-command`, `JX_MEET_BROWSER_REALTIME_CMD`, or the same
`JX_MEET_BROWSER_AGENT_CMD` used for joining.

The repo ships starter bridge commands that can be used directly:

```bash
export JX_MEET_BROWSER_REALTIME_CMD="$PWD/bin/meet-browser-realtime"
export JX_MEET_CONSULT_CMD="$PWD/bin/meet-consult-codex"
export JX_MEET_BROWSER_SPEECH_OUT_CMD="$PWD/bin/meet-speech-output"
```

`bin/meet-browser-realtime` delegates to `JX_MEET_BROWSER_AGENT_CMD` when a real
browser agent is configured. Without one, it reads `JX_MEET_CAPTION_FILE` or
`tmp/meet-captions.json`, then falls back to the chat input queue.
`bin/meet-consult-codex` calls `codex exec` when available and otherwise returns a safe
fallback JSON response. `bin/meet-speech-output` wraps the local macOS speech
helper.

`jx meet realtime watch` is the autonomous loop. Each browser-agent caption/chat
snapshot is normalized into transcript text, deduplicated by hash, and passed
through the full consult path so the current call brief and durable handoff
tools stay in the loop. Use `--caption-file <path>` for caption snapshots,
`--chat-file <path>` for Meet chat/message snapshots, or a browser-agent command
that returns either shape. Use `--iterations 0` for a long-running watcher. Add
`--speak --speech-output-command <cmd>` only when an output bridge is available.
For local macOS testing, `scripts/meet_speech_output.sh` reads the spoken
response from stdin. Set `JX_MEET_SPEECH_OUTPUT_FILE=/tmp/meet.aiff` to render a
file without sending audio, or route the default audio output into a virtual mic
before using it live.

`scripts/meet_voice_egress_watch.sh <session-id>` wraps the watch loop with
`--speak` and the local speech command. It is safe by default: unless
`JX_MEET_SPEECH_LIVE=1` is set, it writes speech to `tmp/meet-speech-latest.aiff`
instead of playing it. For live voice egress, route macOS output to the virtual
mic that Meet is using, then run:

```bash
JX_MEET_SPEECH_LIVE=1 scripts/meet_voice_egress_watch.sh met-abc123def0
```

For in-call message egress, `scripts/meet_chat_egress_watch.sh <session-id>`
wraps the watch loop with a chat queue command. Generated responses are written
to `tmp/meet-chat-latest.txt` and appended to `tmp/meet-chat-outbox.txt`; a
separate browser action can then paste/send the approved text into Meet chat.
When Meet captions are unavailable, `scripts/meet_chat_bridge_watch.sh
<session-id>` watches `tmp/meet-chat-input.txt` as the input side and writes
responses to the same chat outbox. Queue a new input turn with:

```bash
scripts/meet_chat_input_queue.sh "What should we do next?"
```

For audio-level ingress, install BlackHole, set the macOS default input to
`BlackHole 2ch`, route Meet output to BlackHole, and run the combined STT/chat
bridge:

```bash
OPENAI_API_KEY=... scripts/meet_audio_chat_bridge.sh met-abc123def0
```

The audio bridge records short default-input segments, transcribes them with the
OpenAI audio transcription endpoint, writes each non-empty transcript through
`scripts/meet_chat_input_queue.sh`, and leaves response egress on the existing
chat outbox path.

A browser agent can replace that helper by writing the latest Meet chat snapshot
to `--chat-file`; JSON may use `messages`, `chat`, `sender`, `message`, `text`,
or plain transcript text.

Use `--consult-command <cmd>` when the Meet participant should answer through a
local agent process. The command receives a JSON payload on stdin with the Meet
session and transcript. It may return plain text, or JSON such as:

```json
{
  "response": "I can hear you in Meet and I am tracking the work.",
  "summary": "Operator asked Codex to join the live meeting.",
  "decisions": ["continue in Meet"],
  "follow_ups": ["keep caption watcher running"]
}
```

The `response` is the text sent to the speech output bridge when `--speak` is
enabled; the summary, decisions, and follow-ups are preserved in the durable
Meet handoff.

The live audio loop stays gated. `--live` requires explicit
`--approve-audio-capture` and `--approve-speech-output`, because meeting audio
may be sent to a realtime provider and synthesized speech may be transmitted
back into Meet. Caption watching and local transcript handoffs also require
`--approve-notes-or-transcription`. Browser-agent audio also needs configured
ingress and egress commands, a joined browser-agent tab, or a Twilio
bidirectional `Connect/Stream` bridge.

## Recovery

Recover already-open Meet tabs from Chrome remote debugging:

```bash
jx meet recover \
  --debug-url http://127.0.0.1:9222 \
  --paired-debug-url http://127.0.0.1:9223 \
  --meeting abc-mnop-xyz
```

For offline recovery tests or captured Chrome target lists, use
`--targets-json` and `--paired-targets-json`.

## Artifacts And Attendance

```bash
jx meet sync met-abc123def0 --json
jx meet export met-abc123def0 --dir ./meet-artifacts
```

Exports include `session.json`, `handoff.md`, `attendance.csv`, and `twilio.xml`
when Twilio is configured.
