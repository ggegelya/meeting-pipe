# Detection regression corpus

Each trace here replays a recorded scenario through `PromotionEngine` (meeting
start/end lifecycle) and `MicGate.decide` (mute gating) and asserts the produced
verdict sequence matches the captured expectation, so a regression in either is
caught by CI (`DetectionCorpusTests`). Since T8 a third kind, `engine: "lifecycle"`,
replays the whole end decision (the engine, the host's hold and Teams' teardown
oracle together) from raw signal rows. `INDEX.json` lists the active scenarios.

## The rule (T8)

**An END or REC change lands with this replay green, and a fix for an end-of-call
incident lands with a new raw trace of that incident** (`engine: "lifecycle"`,
`origin: "raw"`, extracted with `--raw` below), whose `expected_outcome` is the
correct one. Each END fix from END9 to END14 was validated only by the next real
meeting, because the corpus could not express the incident; a raw trace is how the
fix is shown to hold against what actually happened. When the incident happened on
another Mac, the spec names the UTC window and the owner runs the extraction there.

The corpus is nine synthetic seeds, twenty real dogfood traces
(`teams_native_{rewalk,debounce,flicker}_end_*`) derived from the daemon event
log by `scripts/extract_detection_trace.py`, and seven synthetic incident traces
END17 added (`teams_native_end{9,12,13,14,15}_*`,
`google_meet_browser_tab_away_ten_minutes`), each built from the raw rows its END
spec quotes and marked `"expected_outcome": "no_end"`: a live call that must
never reach `.ended`. T8 replaces them with raw extracted traces once those exist;
until then they stay. T8 added the lifecycle kind with four synthetic traces
(`*_lifecycle_*`: a Teams teardown leave, a Zoom pair-dwell leave with its trim
point, and the host halves of END9 and END12 that the engine-only traces could not
express) and one raw trace from the owner's personal Mac
(`safari_browser_raw_tab_left_held`, 2026-10-16, a browser hold the owner stopped
by hand 20 s in). The END incident windows themselves are in the work laptop's log,
not that one, so they are still owed. The seeds lock in the format and the
cross-app scenarios (Zoom / Webex / Meet / PWA); the real traces cover the
endings actually observed in dogfood. Real traces are derived from live meetings,
which means the source carries meeting subjects, customer names, and other PII,
so every real trace is redacted before it lands (see below).

### Coverage reality (honest scope, TECH-C6)

The twenty real traces are **all `com.microsoft.teams2` native**, because that is
the only client this user records; the cross-app seeds stay synthetic until real
meetings on those clients exist. Three engine paths are represented, all seen in
real sessions: `rewalk_end` (ax-leave-led end confirmed by the host, the
dominant real ending), `debounce_end` (a lone shareable-window-gone end the
pre-END17 engine promoted on its 2 s debounce; END17 confirms it on the 12 minute
lone dwell, so the trace's `tick` sits there), and `flicker_rewalk_end` (a share
re-render flickers the end signals before the real leave, the END6/END8
fragmentation path). Since END17 the timing a real trace asserts is the current
engine's, not the log's: the verdict sequence, leading signal and flicker count
are the log's, and the moment of the end is when today's engine would end it.

The extractor also reports a skipped bucket, and C7 measured what it actually is,
because the first reading of it was wrong. A lone ax-leave `.ended` with empty
`confirmed_by` (23 of 100 armed sessions) is **pre-END2 history, not the idle-stop
backstop**: every one of those sessions ended on or before 2026-06-09, and END2
landed on 2026-06-10 and made the engine refuse that promotion. Replaying one
would assert the exact behaviour END2 removed, so the corpus deliberately does not.

The idle-stop backstop is not in that bucket and cannot be: it force-stops the
recording, not the lifecycle, so it emits `coordinator.auto_stop_silence` then
`lifecycle.idle` and never a `lifecycle.ended` verdict for a trace to assert on.
The shipped `IdleStopBackstop` (END3, 2026-06-10) has also never auto-stopped a
real recording; the log's two `auto_stop_silence` events both predate it and came
from the retired `MicOnlySilenceBackstop`. Its logic is covered directly by
`IdleStopBackstopTests` and `SilenceAutoStopPolicyTests` instead. Full measurement
in C7's entry in `docs/backlog/q6-final.md`.

### Deriving more real traces

`scripts/extract_detection_trace.py` segments a real `events.jsonl` into meetings
and emits redaction-clean draft traces (pid 1234, no titles) whose replay through
the pure engine reproduces the verdict sequence the shipped engine logged live. It
only emits endings it can faithfully reproduce and reports the rest:

```bash
scripts/extract_detection_trace.py --inventory                 # per-session breakdown
scripts/extract_detection_trace.py --emit-all --out-dir /tmp/traces
scripts/redact_detection_trace.py /tmp/traces/<name>.json --check   # mandatory PII gate
```

Those are distilled: each reproduces the verdicts the engine of its day logged, so
a false end replays as the false end it was. For an incident, extract the raw
window instead (UTC, a few seconds either side of the rows the spec quotes):

```bash
scripts/extract_detection_trace.py --raw --from 2026-10-22T12:14:50Z --to 2026-10-22T12:15:25Z \
    --scenario teams_native_end15_mic_switch_raw --out teams_native_end15_mic_switch_raw.json
scripts/redact_detection_trace.py teams_native_end15_mic_switch_raw.json --check
# later, on the same Mac: does the committed file still reproduce from the log?
scripts/extract_detection_trace.py --raw --from <same> --to <same> --check-against <committed>.json
```

It reads the window's `signal`, `coordinator` and `lifecycle` rows for one meeting
app (`--bundle` when the window names several), copies only closed-vocabulary
fields (no title, no file name, no workflow name ever leaves the log), and carries
in each signal's last reading and the recording's start from before the window at
their real negative offsets. It writes `"expected_outcome": "no_end"` unless told
`--expect ended`, because the log records what happened, not what should have. Rows
it cannot map are reported on stderr: `window_title_changed` (decided by a title,
which never leaves), and the retired confirms (`oracle_unavailable`,
`hold_cap_reached`, `live_signal_ceiling_reached`, the pre-END9 empty re-walk),
which are not teardown evidence and so are deliberately not replayed.

## Redaction note (read before committing any real trace)

This corpus is committed to a public repository. A trace must contain only the
structural signal, never meeting content. Before a real trace lands:

- **Titles: strip or placeholder every one.** Window titles, browser tab
  titles, and meeting subjects (`window_title` / `browser_tab_title` events, any
  `title` field) routinely name people and projects. Replace them with a neutral
  placeholder (`"[redacted-title]"`), or drop the field if the test does not key
  on it. Never commit a real subject line.
- **PIDs: drop the real value.** Use the synthetic constant `1234` the seeds
  use. A real pid is not sensitive on its own but it is noise, and pinning it
  keeps diffs clean.
- **Keep only the closed signal vocabulary.** Promotion-engine `events[].kind`
  must be one of the signal kinds: `shareable_content_window`,
  `process_audio_is_running_input_false`, `ax_leave_button`, `browser_tab_title`,
  `workspace_app_terminated`, `window_title`; or a control pseudo-event: `tick`
  (advance the engine's clock, which is how END17's dwells confirm) or
  `confirm_provisional_end` (the host's definitive confirm,
  `PromotionEngine.confirmProvisionalEnd`, which since END17 means Teams'
  teardown line for this recording; `rewalk_signal` names the evidence,
  `call_teardown_observed` today and `ax_leave_rewalk` in traces extracted
  before it). Anything else the loader
  rejects; do not invent kinds to carry extra data.
- **No free text, anywhere.** No emails, URLs, `@`-mentions, or notes. The only
  human-readable strings should be `scenario`, `description` (write it yourself,
  generic), and a `label`. This matches the SEC6 owner/attendee scrub posture.
- **Never commit raw `events.jsonl`.** It is the unredacted source. Derive a
  trace from it, redact, and commit only the trace.
- **Locale:** meetings are English or Ukrainian here. Keep `expected_locale` /
  AX-label examples to `en` / `uk` unless you are deliberately testing another
  locale's mute labels.

Run every candidate through the redaction helper before committing. It rewrites
pids and title fields and fails on any residual PII or unknown signal kind, and
since T8 `--check` also fails a file that still needs that rewrite (it used to
redact in memory and pass); every key of a lifecycle trace is closed, so an
unexpected field is an error rather than a place for a title to hide.
`pipeline/tests/test_detection_trace_scripts.py` runs the strict check over every
committed trace:

```bash
scripts/redact_detection_trace.py draft.json --out teams_native_<scenario>.json
scripts/redact_detection_trace.py teams_native_<scenario>.json --check   # validate in place
```

## Trace format

Three engine shapes. See the seeds for full examples.

**`engine: "promotion"`** drives `PromotionEngine` over a timeline:

```json
{
  "scenario": "teams_native_clean_leave_en",
  "description": "generic, PII-free description you write",
  "engine": "promotion",
  "context": { "bundle_id": "com.microsoft.teams2", "kind": "native", "pid": 1234 },
  "events": [ {"t": 0.0, "kind": "shareable_content_window", "state": "live"} ],
  "expected_verdicts": [ {"after": "events[0]", "verdict": "in_meeting"} ]
}
```

A signal `state` is `"live"` or `"ended"`. `expected_verdicts[].leading` /
`confirmed_by` use the raw signal values (e.g. `shareable_content_window_gone`,
`ax_leave_button_invalid`), not the short `events[].kind`. The `after` field is
documentation only; the replay compares the verdict sequence positionally. An
optional `"expected_outcome": "no_end"` additionally fails the replay if any
`.ended` verdict appears, whatever `expected_verdicts` says. The engine runs at
its default dwells (60 s pair, 720 s lone); the old `debounce_seconds` field is
gone with the debounce. A real `rewalk_end` trace (the dominant native ending)
ends with the host's confirm event rather than a `tick`:

```json
"events": [
  {"t": 0.0,  "kind": "ax_leave_button", "state": "live"},
  {"t": 42.1, "kind": "ax_leave_button", "state": "ended"},
  {"t": 42.1, "kind": "confirm_provisional_end", "rewalk_signal": "ax_leave_rewalk"}
],
"expected_verdicts": [
  {"after": "events[0]", "verdict": "starting"},
  {"after": "events[0]", "verdict": "in_meeting"},
  {"after": "events[1]", "verdict": "ending_provisional", "leading": "ax_leave_button_invalid"},
  {"after": "events[2]", "verdict": "ended", "leading": "ax_leave_button_invalid", "confirmed_by": ["ax_leave_rewalk"]}
]
```

**`engine: "micgate"`** feeds states to `MicGate.decide`:

```json
{
  "scenario": "micgate_silent_by_rms_default",
  "description": "...",
  "engine": "micgate",
  "states": [
    {
      "label": "silent_default",
      "state": { "hal_system_mute": false, "ax_mute": null, "hal_vad": false,
                 "rms_state": "closed", "rms_close_dwell_millis": 400 },
      "expected_verdict": "silent_by_rms",
      "expected_dwell": 400
    }
  ]
}
```

**`engine: "lifecycle"`** (T8) replays `PromotionEngine`, `TeardownHoldPolicy` and
`CallTeardownOracle.decide` together, wired as `MeetingSessionController` wires them,
on a virtual clock (`LifecycleTraceReplay`): the engine tick runs every 0.25 s while a
provisional is pending, the hold consults Teams' teardown line when it opens and once
a second after, and a confirmed hold is trimmed at its start when it ran a second or
more. `t` is seconds from the window start and may be negative for state carried in
from before it. There are no control events; the clock runs to `until` by itself.

```json
{
  "scenario": "teams_native_end15_mic_switch_raw",
  "description": "generic, PII-free",
  "engine": "lifecycle",
  "origin": "raw",
  "source_window": {"from": "2026-10-22T12:14:50Z", "to": "2026-10-22T12:15:25Z"},
  "expected_outcome": "no_end",
  "context": {"bundle_id": "com.microsoft.teams2", "kind": "native", "pid": 1234},
  "until": 35.0,
  "events": [
    {"t": -865.0, "kind": "recording_started", "carried": true},
    {"t": 3.286, "kind": "ax_leave_button", "state": "ended"},
    {"t": 3.443, "kind": "live_signal", "value": "call_is_up"},
    {"t": 9.002, "kind": "process_audio_is_running_input_false", "state": "ended"}
  ],
  "logged_verdicts": [
    {"t": 9.006, "verdict": "ended", "leading": "ax_leave_button_invalid",
     "confirmed_by": ["process_audio_is_running_input_false"]}
  ]
}
```

- **Signal events** use the promotion kinds and `state`.
- **Host inputs:** `recording_started` (arms the engine, and is the oracle's floor for
  a previous call's teardown); `teardown_snapshot` (`available`, `teardown_at`,
  `log_written_at`: the watcher's view of Teams' log, consulted the moment it arrives,
  since a snapshot row is the host having read it; `log_written_at` is carried for the
  record and never decides, per END12); `live_signal` (the host's attribution reading,
  inert since END17 moved the veto into the engine); `rewalk` (`found`: the AX
  re-walk's result, inert by design, because an empty walk is not evidence and a found
  button reaches the engine as the re-armed signal's own row).
- **Expected:** `"expected_outcome": "no_end"`, or `"ended"` with `ended_at` and
  `trim_at` (`null` for a sub-second hold), each matched within a second.
- **`origin`** is `raw` or `synthetic`; a synthetic one holds the place of a window
  nobody has extracted yet. **`logged_verdicts`** is what the engine of that day logged,
  kept so the incident reads on its own; it is never asserted.

After adding a trace, append its filename to `INDEX.json` `scenarios`.
