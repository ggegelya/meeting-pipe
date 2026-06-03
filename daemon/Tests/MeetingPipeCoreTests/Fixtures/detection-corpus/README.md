# Detection regression corpus

Each trace here replays a recorded scenario through `PromotionEngine` (meeting
start/end lifecycle) and `MicGate.decide` (mute gating) and asserts the produced
verdict sequence matches the captured expectation, so a regression in either is
caught by CI (`DetectionCorpusTests`). `INDEX.json` lists the active scenarios.

The corpus is nine synthetic seeds today. TECH-C6 needs 20+ **real** dogfood
traces so detection cannot silently regress on the apps and edge cases you
actually hit. Real traces are recorded from live meetings, which means they pass
through your machine carrying meeting subjects, customer names, and other PII.

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
  must be one of: `shareable_content_window`, `process_audio_is_running_input_false`,
  `ax_leave_button`, `browser_tab_title`, `workspace_app_terminated`,
  `window_title`. Anything else the loader rejects; do not invent kinds to carry
  extra data.
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
