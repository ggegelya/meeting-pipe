#!/usr/bin/env bash
#
# Diagnostic for MIC8: does a UI-independent LOCAL signal record a meeting client's
# mute/unmute transitions durably enough to supersede the AX label scrape?
#
# The a-priori analysis (docs/spikes/mic8-native-mute-signals.md) already closes two of
# the three candidate signal classes from documentation: the vendor SDK path is a
# non-starter (Zoom staff confirm the desktop client exposes no external interaction;
# the Meeting SDK's onUserAudioStatusChange requires HOSTING the meeting through the
# SDK, not observing the user's own Zoom.app), and the OS-level path is a category
# error (CoreAudio device mute is the hardware input, not the app's client-side mute,
# which by design leaves the OS mic live). That leaves ONE empirically-open thread:
# the client's own local diagnostic LOG. This probe measures it on real hardware,
# because the log format is undocumented and per-app, so only a live mute/unmute cycle
# answers "is there a stable line, and how fast does it appear?".
#
# It is READ-ONLY: it tails existing log files and prints only lines that match a set of
# mute/audio-state tokens. A diagnostic log line is a timestamp + component + event name,
# not transcript content; each match is still truncated to 200 chars as a privacy guard.
# Nothing is written, uploaded, or sent anywhere.
#
# Run it on the owner's Mac DURING a live Zoom or Teams call:
#
#     bash daemon/scripts/mic8-native-mute-probe.sh
#
# Then toggle your mic mute/unmute 3-4 times, noting the wall-clock time of each press.
# Read the output:
#   - A line appears within ~1 s of each press, same token every time -> the log is a
#     candidate durable signal (promote to the MeetMuteAdapter-style plan in the doc).
#   - No line appears (or only on some presses, or the token/format varies) -> the log
#     is not a reliable oracle; MIC8's native-signal bet is a close, and MIC6 (the AX
#     state-attribute read) stays the durable direction.
# Ctrl-C to stop.
#
# NOTE ON ZOOM: Zoom's verbose troubleshooting logging is OPT-IN (System Settings won't
# have it on by default). If the Zoom section below reports "no recent writes", enable it
# first: Zoom > Settings > (report a problem / troubleshooting) to install the logging
# build, reproduce, then re-run. A signal that only exists with troubleshooting logging
# enabled is, by itself, evidence against durability.

set -uo pipefail

# Tokens that a client MIGHT use for a mute-state transition. Broad on purpose: the
# formats are undocumented, so we cast wide and let the owner read which (if any) fire.
TOKENS='mute|unmute|self.?mute|micphone|microphone|mic (on|off|muted|unmuted)|audio.?(mute|status|state).?(change|on|off)|SetAudioMute|onUserAudioStatusChange|isMuted|muteState'

# label:root pairs. We glob each root for diagnostic logs (below) and tail whatever
# exists; being loose about the exact path makes the probe robust to per-version
# relocations of the log dir.
ROOTS=(
  "zoom:$HOME/Library/Logs/zoom.us"
  "zoom:$HOME/Library/Application Support/zoom.us/AAM"
  "teams2:$HOME/Library/Group Containers/UBF8T346G9.com.microsoft.teams/Library/Application Support/Logs"
  "teams2:$HOME/Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams"
  "teams:$HOME/Library/Application Support/Microsoft/Teams"
)

# Chromium/WebView2 (EBWebView) storage and leveldb write-ahead files share the .log/.txt
# extensions but are NOT diagnostic logs (and may hold app state), so we exclude those
# subtrees by path and drop leveldb-style numeric names + cache indexes by filename.
NOISE_DIRS='/(EBWebView|IndexedDB|Local Storage|Session Storage|Service Worker|CacheStorage|shared_proto_db|Sync Data|GPUCache|GrShaderCache|Code Cache|DawnCache|blob_storage|ZxcvbnData|Extension Scripts|Extension Rules|Extension State|File System|WebStorage|Network|Site Characteristics Database)/'
NOISE_FILES='/[0-9]{6}\.log$|/index\.txt$|/MANIFEST|/LOCK$|/CURRENT$'

echo "MIC8 native-mute-signal probe (read-only). Ctrl-C to stop."
echo "Toggle your mic mute/unmute a few times during a live call and note each press time."
echo

FILES=()
LABELS=()
now=$(date +%s)
for pair in "${ROOTS[@]}"; do
  label="${pair%%:*}"
  root="${pair#*:}"
  [ -d "$root" ] || continue
  # Diagnostic logs only: drop the Chromium storage subtrees and leveldb noise, then take
  # the newest few per app (a live call writes the freshest log, so that is where a mute
  # line would land) so the probe tails a handful of relevant files, not a whole tree.
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    mtime=$(stat -f %m "$f" 2>/dev/null || echo 0)
    age=$(( now - mtime ))
    FILES+=("$f")
    LABELS+=("$label")
    if [ "$age" -lt 120 ]; then
      printf '  watching  %-7s %s  (LIVE: written %ss ago)\n' "$label" "$f" "$age"
    else
      printf '  watching  %-7s %s  (stale: ~%sd ago -- app may not be logging now)\n' \
        "$label" "$f" "$(( age / 86400 ))"
    fi
  done < <(
    find "$root" -type f \( -name '*.log' -o -name '*.txt' \) -size -50M -print 2>/dev/null \
      | grep -vaE "$NOISE_DIRS" \
      | grep -vaE "$NOISE_FILES" \
      | while IFS= read -r p; do printf '%s\t%s\n' "$(stat -f %m "$p" 2>/dev/null || echo 0)" "$p"; done \
      | sort -rn | head -6 | cut -f2-
  )
done

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "  no Zoom/Teams text logs found under the known roots."
  echo "  Is the client running? For Zoom, enable troubleshooting logging first (see header)."
  exit 0
fi

echo
echo "Live matches (token lines as they are appended):"
# Tail each file in its own subshell so we keep per-file attribution, filter to the mute
# tokens, and stamp each hit with the wall-clock time so latency vs. your press is visible.
pids=()
for i in "${!FILES[@]}"; do
  f="${FILES[$i]}"
  label="${LABELS[$i]}"
  (
    tail -n0 -F "$f" 2>/dev/null \
      | grep --line-buffered -iE "$TOKENS" \
      | while IFS= read -r line; do
          printf '[%s] %-7s %s\n' "$(date +%H:%M:%S)" "$label" "${line:0:200}"
        done
  ) &
  pids+=("$!")
done

trap 'kill "${pids[@]}" 2>/dev/null' INT TERM EXIT
wait
