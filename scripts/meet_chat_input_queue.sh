#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
INPUT="${JX_MEET_CHAT_INPUT:-$ROOT/tmp/meet-chat-input.txt}"
INBOX="${JX_MEET_CHAT_INBOX:-$ROOT/tmp/meet-chat-inbox.txt}"

if [ "$#" -gt 0 ]; then
  TEXT="$*"
else
  TEXT="$(cat)"
fi

if [ -z "$(printf '%s' "$TEXT" | tr -d '[:space:]')" ]; then
  printf '%s\n' "skipped: empty chat input"
  exit 0
fi

mkdir -p "$(dirname "$INPUT")" "$(dirname "$INBOX")"
printf '%s\n' "$TEXT" >"$INPUT"

{
  printf -- '--- %s ---\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '%s\n' "$TEXT"
  printf '\n'
} >>"$INBOX"

printf 'queued chat input: %s\n' "$INPUT"
