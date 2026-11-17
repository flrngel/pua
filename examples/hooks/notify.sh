#!/bin/sh
# hooks.call_ended example: a macOS notification after each call.
# stdin: the call summary as JSON (caller, reason, seconds, turns, transcript, files).
# env:   PUA_EVENT=call_ended, PUA_RECORD_DIR=<folder> when the call was recorded.
payload=$(cat)
get() { printf '%s' "$payload" | plutil -extract "$1" raw -o - - 2>/dev/null; }
caller=$(get caller)
[ -n "$caller" ] || caller="Unknown caller"
seconds=$(get seconds)
message="$(get turns) turns, ${seconds%.*} s${PUA_RECORD_DIR:+, saved}"
osascript -e 'on run argv' \
  -e 'display notification (item 2 of argv) with title "pua" subtitle (item 1 of argv)' \
  -e 'end run' "$caller" "$message"
