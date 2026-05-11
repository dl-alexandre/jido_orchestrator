#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

if [ "$#" -lt 1 ]; then
  printf '%s\n' "usage: scripts/meet_voice_egress_watch.sh <session-id> [extra jx watch args...]" >&2
  exit 64
fi

SESSION_ID="$1"
shift

JX_BIN="${JX_BIN:-$ROOT/jx}"
SPEECH_CMD="${JX_MEET_SPEECH_OUTPUT_CMD:-$ROOT/scripts/meet_speech_output.sh}"
ITERATIONS="${JX_MEET_WATCH_ITERATIONS:-0}"
INTERVAL_MS="${JX_MEET_WATCH_INTERVAL_MS:-1000}"
MIN_CHARS="${JX_MEET_WATCH_MIN_CHARS:-12}"

if [ "${JX_MEET_SPEECH_LIVE:-0}" != "1" ] && [ -z "${JX_MEET_SPEECH_OUTPUT_FILE:-}" ]; then
  mkdir -p "$ROOT/tmp"
  export JX_MEET_SPEECH_OUTPUT_FILE="$ROOT/tmp/meet-speech-latest.aiff"
fi

exec "$JX_BIN" meet realtime watch "$SESSION_ID" \
  --iterations "$ITERATIONS" \
  --interval-ms "$INTERVAL_MS" \
  --min-chars "$MIN_CHARS" \
  --speak \
  --speech-output-command "$SPEECH_CMD" \
  "$@"
