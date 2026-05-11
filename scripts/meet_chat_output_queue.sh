#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LATEST="${JX_MEET_CHAT_LATEST:-$ROOT/tmp/meet-chat-latest.txt}"
OUTBOX="${JX_MEET_CHAT_OUTBOX:-$ROOT/tmp/meet-chat-outbox.txt}"

TMP_TEXT="${TMPDIR:-/tmp}/jx-meet-chat-$$.txt"
trap 'rm -f "$TMP_TEXT"' EXIT HUP INT TERM

cat >"$TMP_TEXT"

if [ ! -s "$TMP_TEXT" ]; then
  printf '%s\n' "skipped: empty chat message"
  exit 0
fi

mkdir -p "$(dirname "$LATEST")" "$(dirname "$OUTBOX")"
cp "$TMP_TEXT" "$LATEST"

{
  printf -- '--- %s ---\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  cat "$TMP_TEXT"
  printf '\n'
} >>"$OUTBOX"

printf 'queued chat message: %s\n' "$LATEST"
