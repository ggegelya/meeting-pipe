# Live-recording guard for rebuild.sh and install.sh (DIST9).
#
# A rebuild or reinstall relaunches the daemon, and a relaunch ends any meeting
# being recorded (the SIGTERM flush keeps what was captured, orphan recovery
# picks it up at the next launch, and the rest of the meeting is never
# recorded). Nothing in the daemon answers "are you recording" to a script, so
# this reads the nearest on-disk signal: `MeetingSessionController` writes
# `<stem>.recovery.json` beside the recording at start and removes it on a clean
# finish. A failed finish leaves one behind for orphan recovery too, so the
# manifest is a superset of "live"; together with a running daemon it counts as
# live, and a stale one costs one extra question, never a lost meeting.
#
# The predicates are text-in, verdict-out on purpose, so
# scripts/test-rebuild-guard.sh can pin them on canned input without a daemon,
# a TTY or a real recordings directory. DIST5's relaunch helper, when it lands,
# folds this in.

# live_recording_output_dir <config.toml path> <home>
#   The recordings directory, resolved the way the pipeline's `mp` resolves
#   `recording.output_dir`: the `[recording]` table's `output_dir`, `~` expanded,
#   else the default `~/Documents/Meetings/raw`. A missing or unreadable config
#   is the default, which is where the daemon writes when it has none either.
live_recording_output_dir() {
    local config="$1" home="$2" dir=""
    if [[ -r "$config" ]]; then
        dir="$(awk '
            /^[[:space:]]*\[/ {
                line = $0
                gsub(/[[:space:]]/, "", line)
                in_recording = (line == "[recording]")
                next
            }
            in_recording && /^[[:space:]]*output_dir[[:space:]]*=/ {
                value = $0
                sub(/^[^=]*=[[:space:]]*/, "", value)
                if (value ~ /^"/) { sub(/^"/, "", value); sub(/".*$/, "", value) }
                else if (value ~ /^'\''/) { sub(/^'\''/, "", value); sub(/'\''.*$/, "", value) }
                else { sub(/[[:space:]]*#.*$/, "", value); sub(/[[:space:]]+$/, "", value) }
                print value
                exit
            }
        ' "$config" 2>/dev/null)" || dir=""
    fi
    [[ -n "$dir" ]] || dir="~/Documents/Meetings/raw"
    case "$dir" in
        "~") dir="$home" ;;
        "~/"*) dir="$home/${dir#\~/}" ;;
    esac
    printf '%s\n' "$dir"
}

# live_recording_manifests <recordings dir>
#   The `<stem>.recovery.json` names in that directory, one per line, sorted.
#   Prints nothing when there are none or the directory is absent.
live_recording_manifests() {
    local dir="$1" f
    [[ -d "$dir" ]] || return 0
    for f in "$dir"/*.recovery.json; do
        [[ -e "$f" ]] || continue
        basename "$f"
    done | LC_ALL=C sort
}

# live_recording_verdict <daemon running: 0|1> <manifests, newline-separated> <tty: 0|1> <force: 0|1>
#   proceed  nothing may be live, or --force was given
#   ask      something may be live and there is a terminal to ask on
#   refuse   something may be live, no terminal, no --force (the caller exits 2)
live_recording_verdict() {
    local running="$1" manifests="$2" tty="$3" force="$4"
    if [[ "$running" != 1 || -z "$manifests" ]]; then
        echo proceed
    elif [[ "$force" == 1 ]]; then
        echo proceed
    elif [[ "$tty" == 1 ]]; then
        echo ask
    else
        echo refuse
    fi
}

# guard_live_recording <app path> <config.toml path> <force: 0|1> <what: "rebuild"|"reinstall">
#   Runs the check against this machine and acts on the verdict. Returns 0 to go
#   on. Exits 2 on a refusal and 1 when the owner answers no, before anything was
#   touched. Reads the answer from /dev/tty so a piped stdin cannot answer it.
guard_live_recording() {
    local app="$1" config="$2" force="$3" what="$4"
    local running=0 dir manifests tty=0 verdict answer
    pgrep -f "$app/Contents/MacOS/MeetingPipe" >/dev/null 2>&1 && running=1
    dir="$(live_recording_output_dir "$config" "$HOME")"
    manifests="$(live_recording_manifests "$dir")"
    [[ -t 0 && -r /dev/tty ]] && tty=1
    verdict="$(live_recording_verdict "$running" "$manifests" "$tty" "$force")"
    [[ "$verdict" == proceed && -n "$manifests" && "$running" == 1 ]] \
        && printf '\033[1;33m!!\033[0m %s\n' "--force: going on although a recording may be in progress." >&2
    [[ "$verdict" == proceed ]] && return 0

    printf '\033[1;33m!!\033[0m %s\n' "MeetingPipe is running and a recording may be in progress:" >&2
    printf '     %s\n' $manifests >&2
    printf '     %s\n' "(in $dir; a manifest is removed when a recording finishes cleanly, so a leftover one from an unrecovered recording shows here too)" >&2
    printf '     %s\n' "A $what relaunches the daemon, which ends that recording. What was captured is kept and recovered at the next launch; the rest of the meeting is not recorded." >&2
    if [[ "$verdict" == refuse ]]; then
        printf '\033[1;31mxx\033[0m %s\n' "No terminal to ask on, so nothing was changed. Stop the recording first, or pass --force." >&2
        exit 2
    fi
    printf '%s' "Go on and end it? [y/N] " >&2
    answer=""
    read -r answer </dev/tty || answer=""
    case "$answer" in
        y|Y|yes|YES|Yes) return 0 ;;
    esac
    printf '\033[1;31mxx\033[0m %s\n' "Nothing was changed; the recording is still running." >&2
    exit 1
}
