#!/usr/bin/env sh
set -eu

VOICE="${JX_MEET_SPEECH_VOICE:-Samantha}"
RATE="${JX_MEET_SPEECH_RATE:-185}"
OUTPUT_FILE="${JX_MEET_SPEECH_OUTPUT_FILE:-}"

TMP_TEXT="${TMPDIR:-/tmp}/jx-meet-speech-$$.txt"
trap 'rm -f "$TMP_TEXT"' EXIT HUP INT TERM

cat >"$TMP_TEXT"

if [ ! -s "$TMP_TEXT" ]; then
  printf '%s\n' "skipped: empty speech text"
  exit 0
fi

if [ -n "$OUTPUT_FILE" ]; then
  mkdir -p "$(dirname "$OUTPUT_FILE")"
  say -v "$VOICE" -r "$RATE" -o "$OUTPUT_FILE" -f "$TMP_TEXT"
  printf 'wrote speech audio: %s\n' "$OUTPUT_FILE"
  exit 0
fi

say -v "$VOICE" -r "$RATE" -f "$TMP_TEXT"
printf '%s\n' "sent speech to default audio output"
