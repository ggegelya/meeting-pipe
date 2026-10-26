#!/usr/bin/env python3
"""TECH-C6 helper: redact and validate a detection-corpus trace before it is
committed to the public repo.

Real dogfood traces are derived from a live `events.jsonl` window and carry
meeting content (window titles, subjects) plus noise (real pids). This pass
enforces the redaction note in
`daemon/Tests/MeetingPipeCoreTests/Fixtures/detection-corpus/README.md`:

  - rewrites every `pid` to the synthetic constant 1234,
  - replaces title-bearing fields with a neutral placeholder,
  - validates the trace shape and the closed promotion signal vocabulary,
  - fails (nonzero exit, no write) on any residual PII (email, URL, @-mention),
    so the stop-and-ask is mechanical, not a matter of remembering.

It does NOT invent `expected_verdicts`; you author those from the real session.

Usage:
  scripts/redact_detection_trace.py draft.json --out teams_native_x.json
  scripts/redact_detection_trace.py teams_native_x.json --check   # validate, no write
  cat draft.json | scripts/redact_detection_trace.py -            # stdin -> stdout

Stdlib only.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

PLACEHOLDER = "[redacted-title]"
SYNTHETIC_PID = 1234

# Keys whose values are human-readable titles / labels that may name people or
# projects. Replaced wholesale; the test should not key on their text.
TITLE_KEYS = {
    "title", "window_title", "tab_title", "browser_tab_title",
    "meeting_title", "subject", "ax_label",
}

# Closed promotion-engine signal vocabulary (mirrors the loader's mapSignalKind).
SIGNAL_KINDS = {
    "shareable_content_window",
    "process_audio_is_running_input_false",
    "ax_leave_button",
    "browser_tab_title",
    "workspace_app_terminated",
    "window_title",
}

# Control pseudo-events the corpus loader (DetectionCorpusTests) understands in a
# promotion timeline alongside the signal kinds: `tick` advances the engine's clock (END17's
# dwells); `confirm_provisional_end` is the host's definitive confirm
# (PromotionEngine.confirmProvisionalEnd). Lifecycle traces have no control events: their
# clock runs on its own, and their host inputs are validated by `validate_lifecycle`.
# They carry no meeting content, so they are valid but are not signal kinds.
CONTROL_KINDS = {"tick", "confirm_provisional_end"}

EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")
URL = re.compile(r"https?://", re.IGNORECASE)
MENTION = re.compile(r"(?:^|[\s(])@\w+")


def redact(obj: object) -> object:
    """Recursively rewrite pids and title fields in place."""
    if isinstance(obj, dict):
        for key, value in list(obj.items()):
            if key == "pid":
                obj[key] = SYNTHETIC_PID
            elif key in TITLE_KEYS and isinstance(value, str):
                obj[key] = PLACEHOLDER
            else:
                redact(value)
    elif isinstance(obj, list):
        for item in obj:
            redact(item)
    return obj


def validate(trace: dict) -> list[str]:
    errors: list[str] = []
    engine = trace.get("engine")
    if engine not in {"promotion", "micgate", "lifecycle"}:
        errors.append(f"engine must be 'promotion', 'micgate' or 'lifecycle', got {engine!r}")
    if engine == "promotion":
        for i, event in enumerate(trace.get("events", [])):
            kind = event.get("kind") if isinstance(event, dict) else None
            if kind not in SIGNAL_KINDS and kind not in CONTROL_KINDS:
                errors.append(f"events[{i}].kind {kind!r} is not in the closed signal or control vocabulary")
    if engine == "lifecycle":
        errors += validate_lifecycle(trace)
    return errors


# T8: an `engine: "lifecycle"` trace (raw from `extract_detection_trace.py --raw`, or a
# synthetic placeholder). Every key is closed, because a raw trace is built from a real
# log and an open key is where a title would slip through.
LIFECYCLE_KEYS = {
    "scenario", "description", "engine", "origin", "source_window", "expected_outcome",
    "ended_at", "trim_at", "context", "until", "events", "logged_verdicts",
}
# Host inputs the replay reads, with the keys each may carry besides `t` and `kind`.
HOST_KINDS = {
    "recording_started": set(),
    "teardown_snapshot": {"available", "teardown_at", "log_written_at"},
    "live_signal": {"value"},
    "rewalk": {"found"},
}
LIVE_SIGNALS = {"call_is_up", "call_is_down", "unknown"}
VERDICTS = {"idle", "starting", "in_meeting", "ending_provisional", "ended"}
TOKEN = re.compile(r"^[a-z][a-z0-9_]*$")
ISO = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z$")


def _num(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def validate_lifecycle(trace: dict) -> list[str]:
    errors = [f"unknown top-level key {k!r}" for k in sorted(set(trace) - LIFECYCLE_KEYS)]
    if trace.get("origin") not in {"raw", "synthetic"}:
        errors.append("origin must be 'raw' or 'synthetic'")
    outcome = trace.get("expected_outcome")
    if outcome not in {"no_end", "ended"}:
        errors.append("expected_outcome must be 'no_end' or 'ended'")
    if outcome == "ended":
        if not _num(trace.get("ended_at")):
            errors.append("an 'ended' trace needs a numeric ended_at")
        if trace.get("trim_at") is not None and not _num(trace.get("trim_at")):
            errors.append("trim_at must be a number or null")
    if not _num(trace.get("until")):
        errors.append("until must be a number (seconds from the window start)")
    context = trace.get("context")
    if not isinstance(context, dict) or set(context) - {"bundle_id", "kind", "pid"} \
            or context.get("kind") not in {"native", "browser"}:
        errors.append("context must be {bundle_id, kind: native|browser, pid}")
    window = trace.get("source_window")
    if window is not None and (not isinstance(window, dict) or set(window) != {"from", "to"}
                               or not all(isinstance(v, str) and ISO.match(v) for v in window.values())):
        errors.append("source_window must be {from, to} as UTC ISO timestamps")
    for i, event in enumerate(trace.get("events", [])):
        where = f"events[{i}]"
        if not isinstance(event, dict) or not _num(event.get("t")):
            errors.append(f"{where} needs a numeric t")
            continue
        kind = event.get("kind")
        extra = set(event) - {"t", "kind", "carried"}
        if kind in SIGNAL_KINDS:
            if event.get("state") not in {"live", "ended"}:
                errors.append(f"{where} signal state must be live or ended")
            extra -= {"state"}
        elif kind in HOST_KINDS:
            extra -= HOST_KINDS[kind]
            if kind == "teardown_snapshot":
                if not isinstance(event.get("available"), bool):
                    errors.append(f"{where} teardown_snapshot needs a boolean available")
                for key in ("teardown_at", "log_written_at"):
                    if event.get(key) is not None and not _num(event.get(key)):
                        errors.append(f"{where}.{key} must be a number or null")
            elif kind == "live_signal" and event.get("value") not in LIVE_SIGNALS:
                errors.append(f"{where} live_signal value must be one of {sorted(LIVE_SIGNALS)}")
            elif kind == "rewalk" and not isinstance(event.get("found"), bool):
                errors.append(f"{where} rewalk needs a boolean found")
        else:
            errors.append(f"{where}.kind {kind!r} is not a signal kind or a lifecycle host input")
            continue
        if "carried" in event and event["carried"] is not True:
            errors.append(f"{where}.carried is only ever true")
        if extra:
            errors.append(f"{where} carries unknown key(s) {sorted(extra)}")
    for i, rec in enumerate(trace.get("logged_verdicts", [])):
        where = f"logged_verdicts[{i}]"
        if not isinstance(rec, dict) or set(rec) - {"t", "verdict", "leading", "confirmed_by"} \
                or not _num(rec.get("t")) or rec.get("verdict") not in VERDICTS:
            errors.append(f"{where} must be {{t, verdict, leading?, confirmed_by?}} with a known verdict")
            continue
        tokens = ([rec["leading"]] if "leading" in rec else []) + list(rec.get("confirmed_by", []))
        if not all(isinstance(tok, str) and TOKEN.match(tok) for tok in tokens):
            errors.append(f"{where} leading/confirmed_by must be snake_case signal tokens")
    return errors


def needs_redaction(trace: dict) -> bool:
    """True when `redact` would change a timeline trace: a real pid or a title is still in it.

    A micgate trace is exempt: its one title-keyed field is `ax_label`, the mute button's own
    label ("Mute", "Unmute"), which its replay asserts on, so blanking it would break the
    trace rather than clean it. `scan_pii` still runs over it."""
    if trace.get("engine") == "micgate":
        return False
    return redact(json.loads(json.dumps(trace))) != trace


def scan_pii(obj: object, path: str = "") -> list[str]:
    findings: list[str] = []
    if isinstance(obj, dict):
        for key, value in obj.items():
            findings += scan_pii(value, f"{path}.{key}" if path else key)
    elif isinstance(obj, list):
        for i, item in enumerate(obj):
            findings += scan_pii(item, f"{path}[{i}]")
    elif isinstance(obj, str):
        if EMAIL.search(obj):
            findings.append(f"{path}: looks like an email ({obj!r})")
        if URL.search(obj):
            findings.append(f"{path}: contains a URL ({obj!r})")
        if MENTION.search(obj):
            findings.append(f"{path}: contains an @-mention ({obj!r})")
    return findings


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Redact + validate a detection-corpus trace.")
    ap.add_argument("input", help="trace JSON path, or - for stdin")
    ap.add_argument("--out", type=Path, default=None,
                    help="write the redacted trace here (default: stdout, unless --check)")
    ap.add_argument("--check", action="store_true",
                    help="validate only; do not write")
    args = ap.parse_args(argv)

    raw = sys.stdin.read() if args.input == "-" else Path(args.input).read_text(encoding="utf-8")
    try:
        trace = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"error: not valid JSON: {e}", file=sys.stderr)
        return 2
    if not isinstance(trace, dict):
        print("error: trace must be a JSON object", file=sys.stderr)
        return 2

    # T8: `--check` used to redact in memory and then validate, so a file still carrying a real
    # pid or a title passed the gate it is meant to be. It fails on that now; the fix is to
    # run without --check and commit what it writes.
    unredacted = args.check and needs_redaction(trace)
    redact(trace)
    errors = validate(trace)
    if unredacted:
        errors.append("the file still needs redacting (a real pid or a title); run without --check and commit the output")
    pii = scan_pii(trace)

    for err in errors:
        print(f"INVALID  {err}", file=sys.stderr)
    for hit in pii:
        print(f"PII      {hit}", file=sys.stderr)
    if errors or pii:
        print(f"\n{len(errors)} schema error(s), {len(pii)} PII finding(s). "
              "Fix by hand and re-run; nothing written.", file=sys.stderr)
        return 1

    if args.check:
        print("OK: trace is redacted and schema-valid.")
        return 0

    out_text = json.dumps(trace, indent=2, ensure_ascii=False) + "\n"
    if args.out:
        args.out.write_text(out_text, encoding="utf-8")
        print(f"wrote redacted trace to {args.out}")
    else:
        sys.stdout.write(out_text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
