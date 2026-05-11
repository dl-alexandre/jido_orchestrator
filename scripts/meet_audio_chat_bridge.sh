#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

if [ "$#" -lt 1 ]; then
  printf '%s\n' "usage: scripts/meet_audio_chat_bridge.sh <session-id> [extra jx watch args...]" >&2
  exit 64
fi

SESSION_ID="$1"
shift

if [ -n "${JX_MEET_STT_CMD:-}" ]; then
  STT_CMD="$JX_MEET_STT_CMD"
elif [ -n "${OPENAI_API_KEY:-}" ]; then
  STT_CMD="$ROOT/scripts/meet_audio_stt_openai.swift"
else
  STT_CMD="$ROOT/scripts/meet_audio_stt_macos.swift"
fi

case "$STT_CMD" in
  *meet_audio_stt_openai.swift)
    if [ -z "${OPENAI_API_KEY:-}" ]; then
      printf '%s\n' "OPENAI_API_KEY is required for OpenAI audio transcription" >&2
      exit 78
    fi
    ;;
esac

WATCH_CMD="${JX_MEET_CHAT_BRIDGE_CMD:-$ROOT/scripts/meet_chat_bridge_watch.sh}"

"$STT_CMD" &
STT_PID="$!"

"$WATCH_CMD" "$SESSION_ID" "$@" &
WATCH_PID="$!"

cleanup() {
  kill "$STT_PID" "$WATCH_PID" >/dev/null 2>&1 || true
}

trap cleanup EXIT HUP INT TERM

while true; do
  if ! kill -0 "$STT_PID" >/dev/null 2>&1; then
    wait "$STT_PID"
    exit "$?"
  fi

  if ! kill -0 "$WATCH_PID" >/dev/null 2>&1; then
    wait "$WATCH_PID"
    exit "$?"
  fi

  sleep 1
done
