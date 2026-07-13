# Detection regression corpus

Each trace here replays a recorded scenario through `PromotionEngine` (meeting
start/end lifecycle) and `MicGate.decide` (mute gating) and asserts the produced
verdict sequence matches the captured expectation, so a regression in either is
caught by CI (`DetectionCorpusTests`). `INDEX.json` lists the active scenarios.

The corpus is nine synthetic seeds plus twenty real dogfood traces
(`teams_native_*`) derived from the daemon event log by
`scripts/extract_detection_trace.py`. The seeds lock in the format and the
cross-app scenarios (Zoom / Webex / Meet / PWA); the real traces cover the
endings actually observed in dogfood. Real traces are derived from live meetings,
which means the source carries meeting subjects, customer names, and other PII,
so every real trace is redacted before it lands (see below).

### Coverage reality (honest scope, TECH-C6)

The twenty real traces are **all `com.microsoft.teams2` native**, because that is
the only client this user records; the cross-app seeds stay synthetic until real
meetings on those clients exist. Three engine paths are represented, all seen in
real sessions: `rewalk_end` (ax-leave-led end confirmed by the AX re-walk, the
dominant real ending), `debounce_end` (a shareable-window-gone end promoted on the
debounce), and `flicker_rewalk_end` (a share re-render flickers the end signals
before the real leave, the END6/END8 fragmentation path). One real ending is
**not** represented: a lone ax-leave `.ended` with empty `confirmed_by` (the
idle-stop backstop, ~a third of real sessions) is promoted by `IdleStopBackstop`,
not `PromotionEngine`, so it is out of this corpus's scope; covering it needs a
backstop-level harness, filed as a follow-on rather than faked here.

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
  (advance the debounce clock) or `confirm_provisional_end` (fire the AX re-walk
  promotion, `PromotionEngine.confirmProvisionalEnd`). Anything else the loader
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
pids and title fields and fails on any residual PII or unknown signal kind:

```bash
scripts/redact_detection_trace.py draft.json --out teams_native_<scenario>.json
scripts/redact_detection_trace.py teams_native_<scenario>.json --check   # validate in place
```

## Trace format

Two engine shapes. See the seeds for full examples.

**`engine: "promotion"`** drives `PromotionEngine` over a timeline:

```json
{
  "scenario": "teams_native_clean_leave_en",
  "description": "generic, PII-free description you write",
  "engine": "promotion",
  "debounce_seconds": 2.0,
  "context": { "bundle_id": "com.microsoft.teams2", "kind": "native", "pid": 1234 },
  "events": [ {"t": 0.0, "kind": "shareable_content_window", "state": "live"} ],
  "expected_verdicts": [ {"after": "events[0]", "verdict": "in_meeting"} ]
}
```

A signal `state` is `"live"` or `"ended"`. `expected_verdicts[].leading` /
`confirmed_by` use the raw signal values (e.g. `shareable_content_window_gone`,
`ax_leave_button_invalid`), not the short `events[].kind`. The `after` field is
documentation only; the replay compares the verdict sequence positionally. A real
`rewalk_end` trace (the dominant native ending) ends with the AX-re-walk control
event rather than a debounce `tick`:

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

After adding a trace, append its filename to `INDEX.json` `scenarios`.
