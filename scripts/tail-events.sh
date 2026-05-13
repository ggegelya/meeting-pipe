#!/bin/bash
# Pretty-print ~/Library/Logs/MeetingPipe/events.jsonl in real time so a
# detector / coordinator / recorder transition is easy to spot during a
# live test session. Pairs with `scripts/install.sh` so the
# JSONL stream surfaces without an external viewer.
#
# Usage:
#   scripts/tail-events.sh              # follow live (default)
#   scripts/tail-events.sh --all        # print everything that already
#                                         landed, then follow
#   scripts/tail-events.sh --last N     # last N events, then follow
#
# Output format (one line per event):
#   HH:MM:SS  category.action  key1=val1  key2=val2  …
#
# Each line is colourised by category so detector vs coordinator vs
# recorder is glance-readable in a terminal that supports ANSI.

set -e

EVENTS="${HOME}/Library/Logs/MeetingPipe/events.jsonl"
if [ ! -f "$EVENTS" ]; then
    echo "No events file at $EVENTS — has meeting-pipe ever run?" >&2
    exit 1
fi

mode="follow"
last_n=20
while [ $# -gt 0 ]; do
    case "$1" in
        --all)
            mode="all"
            shift
            ;;
        --last)
            mode="lastN"
            last_n="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,16p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown arg: $1" >&2
            exit 1
            ;;
    esac
done

# jq is the cleanest renderer. The pipeline already pulls it in via
# its own toolchain on most installs; fall back to a plain JSON pretty
# print if jq isn't on PATH.
if ! command -v jq >/dev/null 2>&1; then
    echo "jq not found — install via 'brew install jq' for the coloured renderer" >&2
    echo "raw stream follows:" >&2
    case "$mode" in
        all)    tail -n +1 -f "$EVENTS" ;;
        lastN)  tail -n "$last_n" -f "$EVENTS" ;;
        follow) tail -F "$EVENTS" ;;
    esac
    exit 0
fi

# ANSI palette. Categories the daemon emits today: coordinator,
# detector, recorder, correction. Add new keys as they appear; an
# unknown category falls through to the default colour.
render='
  def colour(cat):
    if cat == "detector" then "[36m"        # cyan
    elif cat == "coordinator" then "[33m"   # yellow
    elif cat == "recorder" then "[35m"      # magenta
    elif cat == "correction" then "[32m"    # green
    else "[37m" end;                        # white
  def reset: "[0m";
  . as $e
  | (.ts // "?") as $ts
  | ($ts | sub("^(....-..-..)T"; "") | sub("\\.\\d+Z$"; "")) as $time
  | (colour(.category)) + $time + " " + (.category // "?") + "." + (.action // "?") + reset as $head
  | ([to_entries[]
      | select(.key | IN("ts","category","action") | not)
      | "\(.key)=\(.value | tojson | gsub("^\""; "") | gsub("\"$"; ""))"
    ] | join("  ")) as $attrs
  | if ($attrs | length) > 0 then "\($head)  \($attrs)" else $head end
'

stream() {
    jq -r --unbuffered "$render"
}

case "$mode" in
    all)
        tail -n +1 -f "$EVENTS" | stream
        ;;
    lastN)
        tail -n "$last_n" -f "$EVENTS" | stream
        ;;
    follow)
        # Print one banner so the user knows it's live, then tail from
        # the current EOF.
        echo "tailing $EVENTS (Ctrl-C to stop)" >&2
        tail -n 0 -F "$EVENTS" | stream
        ;;
esac
