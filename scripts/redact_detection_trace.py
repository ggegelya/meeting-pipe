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
# promotion timeline alongside the signal kinds: `tick` advances the debounce clock;
# `confirm_provisional_end` fires the AX re-walk promotion (PromotionEngine.confirmProvisionalEnd).
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
    if engine not in {"promotion", "micgate"}:
        errors.append(f"engine must be 'promotion' or 'micgate', got {engine!r}")
    if engine == "promotion":
        for i, event in enumerate(trace.get("events", [])):
            kind = event.get("kind") if isinstance(event, dict) else None
            if kind not in SIGNAL_KINDS and kind not in CONTROL_KINDS:
                errors.append(f"events[{i}].kind {kind!r} is not in the closed signal or control vocabulary")
    return errors


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

    redact(trace)
    errors = validate(trace)
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
