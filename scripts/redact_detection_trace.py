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
  - fails (nonzero exit, no write) on any residual PII (email, URL, @-mention,
    or on the owner's Mac a roster name, HYG21), so the stop-and-ask is
    mechanical, not a matter of remembering,
  - closes every key of a promotion or lifecycle trace, makes `scenario` a token,
    and bounds the prose `description` (T20).

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
    # T20: every engine. `scenario` names the file and is a token; `description` is the one
    # prose field, so it is bounded and its capitalised words checked.
    scenario = trace.get("scenario")
    if not (isinstance(scenario, str) and TOKEN.match(scenario)):
        errors.append(f"scenario must be a snake_case token, got {scenario!r}")
    errors += validate_description(trace.get("description"))
    if engine == "promotion":
        errors += validate_promotion(trace)
    if engine == "lifecycle":
        errors += validate_lifecycle(trace)
    return errors


# T20: the promotion schema, closed the way `validate_lifecycle` closes its own. Before this a
# promotion trace (35 of 52 committed) accepted any key and any text, and printed OK for one
# naming a person and a company. These are exactly the keys the committed traces use.
PROMOTION_KEYS = {
    "scenario", "description", "engine", "origin", "context", "events",
    "expected_verdicts", "expected_outcome",
}
PROMOTION_EVENT_KEYS = {"t", "kind", "state", "rewalk_signal"}
PROMOTION_VERDICT_KEYS = {"after", "verdict", "leading", "confirmed_by"}
CONTEXT_KEYS = {"bundle_id", "kind", "pid"}
BUNDLE_ID = re.compile(r"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$")
AFTER = re.compile(r"^events\[\d+\]$")


def validate_promotion(trace: dict) -> list[str]:
    errors = [f"unknown top-level key {k!r}" for k in sorted(set(trace) - PROMOTION_KEYS)]
    if "origin" in trace and trace["origin"] not in {"raw", "synthetic"}:
        errors.append("origin must be 'raw' or 'synthetic'")
    if trace.get("expected_outcome") not in {None, "no_end", "ended"}:
        errors.append("expected_outcome must be 'no_end' or 'ended'")
    context = trace.get("context")
    if not isinstance(context, dict):
        errors.append("context must be {bundle_id, kind: native|browser, pid}")
    else:
        errors += [f"context carries unknown key {k!r}" for k in sorted(set(context) - CONTEXT_KEYS)]
        if context.get("kind") not in {"native", "browser"}:
            errors.append("context.kind must be native or browser")
        if not (isinstance(context.get("bundle_id"), str) and BUNDLE_ID.match(context["bundle_id"])):
            errors.append("context.bundle_id must be a reverse-DNS bundle id")
    for i, event in enumerate(trace.get("events", [])):
        where = f"events[{i}]"
        if not isinstance(event, dict):
            errors.append(f"{where} must be an object")
            continue
        kind = event.get("kind")
        if kind not in SIGNAL_KINDS and kind not in CONTROL_KINDS:
            errors.append(f"{where}.kind {kind!r} is not in the closed signal or control vocabulary")
        extra = set(event) - PROMOTION_EVENT_KEYS
        if extra:
            errors.append(f"{where} carries unknown key(s) {sorted(extra)}")
        if "state" in event and event["state"] not in {"live", "ended"}:
            errors.append(f"{where}.state must be live or ended")
        if "rewalk_signal" in event and not (isinstance(event["rewalk_signal"], str)
                                             and TOKEN.match(event["rewalk_signal"])):
            errors.append(f"{where}.rewalk_signal must be a snake_case token")
    for i, rec in enumerate(trace.get("expected_verdicts", [])):
        where = f"expected_verdicts[{i}]"
        if not isinstance(rec, dict):
            errors.append(f"{where} must be an object")
            continue
        extra = set(rec) - PROMOTION_VERDICT_KEYS
        if extra:
            errors.append(f"{where} carries unknown key(s) {sorted(extra)}")
        if rec.get("verdict") not in VERDICTS:
            errors.append(f"{where}.verdict must be one of {sorted(VERDICTS)}")
        if not (isinstance(rec.get("after"), str) and AFTER.match(rec["after"])):
            errors.append(f"{where}.after must be events[<n>]")
        confirmed = rec.get("confirmed_by", [])
        tokens = ([rec["leading"]] if "leading" in rec else []) + (
            list(confirmed) if isinstance(confirmed, list) else [confirmed])
        if not all(isinstance(tok, str) and TOKEN.match(tok) for tok in tokens):
            errors.append(f"{where} leading/confirmed_by must be snake_case signal tokens")
    return errors


# T20: `description` is the one prose field in a trace, so it is where a person's or a
# company's name would land. Bounded in length (the longest committed is 1,003 characters),
# and a capitalised word that does not open a sentence must be an all-caps token (AX, VAD,
# END17, D048), a CamelCase code symbol (ProcessAudio, CallTeardownHoldTests), or one of
# these words, each a product, vendor, UI label or language the committed traces discuss.
# A heuristic, not a guarantee: a name opening a sentence passes, and so does a lowercase one.
# On the owner's Mac the HYG21 roster check (`scan_roster`) covers both.
DESCRIPTION_MAX = 1200
DESCRIPTION_WORDS = {
    "Teams", "Zoom", "Meet", "Google", "Webex", "Cisco", "Chrome", "Safari",  # products, vendors
    "Leave", "Center",  # UI labels: the Leave button, Control Center
    "English", "German",  # the locales a trace is recorded in
}
CAPS_TOKEN = re.compile(r"^[A-Z][A-Z0-9]*(?:-\d+)?$")
CAMEL_SYMBOL = re.compile(r"^[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]*)+$")


def validate_description(description: object) -> list[str]:
    if not isinstance(description, str):
        return ["description must be a string"]
    errors: list[str] = []
    if len(description) > DESCRIPTION_MAX:
        errors.append(f"description is {len(description)} characters, over the {DESCRIPTION_MAX} cap")
    for sentence in re.split(r"(?<=[.!?:;])\s+", description):
        words = re.findall(r"[A-Za-z][A-Za-z0-9-]*", sentence)
        for word in words[1:]:
            if not word[0].isupper() or word in DESCRIPTION_WORDS:
                continue
            if CAPS_TOKEN.match(word) or CAMEL_SYMBOL.match(word):
                continue
            errors.append(f"description: capitalised word {word!r} is not an allowed product, "
                          "acronym or code symbol (a name? reword it generically)")
    return errors


def scan_roster(trace: object, roster: Path | None = None, config: Path | None = None) -> list[str]:
    """HYG21's personal fence, applied to a trace: any whole-word roster name or the owner's
    label in any string fails. Read from the owner's own files through `truth_fences`, never
    from the repo, so it runs on the owner's Mac and is a no-op elsewhere. Reports the path
    and which roster entry, never the name, so the output carries none."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    try:
        import truth_fences
    finally:
        sys.path.pop(0)
    names, _stems, _found = truth_fences.personal_sources(
        roster or truth_fences.DEFAULT_ROSTER, config or truth_fences.DEFAULT_CONFIG, None)
    patterns = [(tag, re.compile(r"(?<![^\W_])" + re.escape(tok) + r"(?![^\W_])", re.IGNORECASE))
                for tag, tok in names]
    findings: list[str] = []

    def walk(obj: object, path: str) -> None:
        if isinstance(obj, dict):
            for key, value in obj.items():
                walk(value, f"{path}.{key}" if path else key)
        elif isinstance(obj, list):
            for i, item in enumerate(obj):
                walk(item, f"{path}[{i}]")
        elif isinstance(obj, str):
            findings.extend(f"{path}: {tag}" for tag, pat in patterns if pat.search(obj))

    walk(trace, "")
    return findings


# T8: an `engine: "lifecycle"` trace (raw from `extract_detection_trace.py --raw`, or a
# synthetic placeholder). Every key is closed, because a raw trace is built from a real
# log and an open key is where a title would slip through.
LIFECYCLE_KEYS = {
    "scenario", "description", "engine", "origin", "source_window", "expected_outcome",
    "ended_at", "trim_at", "context", "until", "events", "logged_verdicts", "truth",
}
# T17: a truth label, written by hand from evidence other than the lifecycle verdict. Exactly
# these keys; `truth_source` names the evidence from a closed vocabulary.
TRUTH_KEYS = {"call_ended_at", "truth_source", "max_overrun_sec"}
TRUTH_SOURCES = {"owner_stop", "redetect", "mic_release", "owner_label"}
# Host inputs the replay reads, with the keys each may carry besides `t` and `kind`.
HOST_KINDS = {
    "recording_started": set(),
    "teardown_snapshot": {"available", "teardown_at", "log_written_at"},
    "live_signal": {"value"},
    "rewalk": {"found"},
    # T17: the host engaged the lifecycle afresh (END27's re-engage); the replay starts a new engine.
    "engage": set(),
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
    if "truth" in trace:
        errors += validate_truth(trace["truth"], trace.get("until"))
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


def validate_truth(truth: object, until: object = None) -> list[str]:
    if not isinstance(truth, dict) or set(truth) != TRUTH_KEYS:
        return [f"truth must carry exactly {sorted(TRUTH_KEYS)}"]
    errors: list[str] = []
    ended, overrun = truth.get("call_ended_at"), truth.get("max_overrun_sec")
    if ended is not None and not _num(ended):
        errors.append("truth.call_ended_at must be a number or null (live for the whole window)")
    if overrun is not None and not _num(overrun):
        errors.append("truth.max_overrun_sec must be a number or null")
    if ended is not None and overrun is None:
        errors.append("truth with a call end needs a max_overrun_sec")
    if _num(ended) and _num(overrun) and _num(until) and not (0 <= ended and ended + overrun < until):
        # A missing end scores an overrun only up to `until`, so a window that cannot outlast the
        # allowed overrun would let a replay that never ends pass on its truth.
        errors.append("truth needs 0 <= call_ended_at and call_ended_at + max_overrun_sec < until")
    if truth.get("truth_source") not in TRUTH_SOURCES:
        errors.append(f"truth.truth_source must be one of {sorted(TRUTH_SOURCES)}")
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
    pii = scan_pii(trace) + [f"{hit} (HYG21 roster)" for hit in scan_roster(trace)]

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
