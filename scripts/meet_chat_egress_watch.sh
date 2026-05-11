#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

if [ "$#" -lt 1 ]; then
  printf '%s\n' "usage: scripts/meet_chat_egress_watch.sh <session-id> [extra jx watch args...]" >&2
  exit 64
fi

SESSION_ID="$1"
shift

JX_BIN="${JX_BIN:-$ROOT/jx}"
CHAT_CMD="${JX_MEET_CHAT_OUTPUT_CMD:-$ROOT/scripts/meet_chat_output_queue.sh}"
ITERATIONS="${JX_MEET_WATCH_ITERATIONS:-0}"
INTERVAL_MS="${JX_MEET_WATCH_INTERVAL_MS:-1000}"
MIN_CHARS="${JX_MEET_WATCH_MIN_CHARS:-12}"

exec "$JX_BIN" meet realtime watch "$SESSION_ID" \
  --iterations "$ITERATIONS" \
  --interval-ms "$INTERVAL_MS" \
  --min-chars "$MIN_CHARS" \
  --speak \
  --speech-output-command "$CHAT_CMD" \
  "$@"
