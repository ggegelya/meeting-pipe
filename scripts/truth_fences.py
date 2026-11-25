#!/usr/bin/env python3
"""CI5: fences that diff what the docs SAY against what the code DOES.

Four failure classes recur in this repo and none is catchable by a type
checker, a linter, or a test:

  1. A **dead knob**: a config key documented in `config.example.toml` or the
     README, rendered as a live Preferences control, parsed and persisted, and
     consumed by nothing. END4(b) fixed one instance; the 2026-07-12 assessment
     found three more, cleared by HYG2 (`transcription.language` wired,
     `recording.sample_rate` and `detection.debounce_start_sec` deleted). The
     user changes the setting and nothing happens.

     **What this fence cannot see, and never will:** it diffs *sets of
     `config.toml` keys*, so a dead knob that is not a TOML key is invisible to
     it. `UISettings` is the live example: its properties are cosmetic
     preferences persisted straight to `UserDefaults`, deliberately kept out of
     `config.toml` so that file stays small and pipeline-parseable, and nothing
     here reads them. ARCH6 found `menuBarIconStyle` and `showRegulatedBadge`
     sitting there with no writer anywhere in the app for a year after DSN1's IA
     pass cut their controls: each was parsed, persisted and branched on, and
     each was permanently pinned at its init default. That is failure class 1
     exactly, and a green fence said nothing. Read a pass here as "no dead
     *config* key", never as "no dead knob". The same blind spot covers any
     other non-TOML setting store added later.
  2. An **undocumented event category**: a `Log.event` / `events.emit` category
     absent from the CONVENTIONS.md table, so a session reading that table to
     orient gets an incomplete map of the event stream.
  3. An **over-budget `CLAUDE.md`**: every one of those files is prepended to
     every prompt in its subtree, so a paragraph added there is re-read on every
     turn forever. `daemon/CLAUDE.md` went 3.8 KB -> 71 KB in three months
     (DOC14), which is ~18k tokens before a session reads a line of code, and
     nothing in the repo noticed. Unlike the first two this is not prose-vs-code
     drift; it is prose-vs-attention. The failure mode is the same though: a rule
     buried in the middle of 7,000 words of incident narrative is a rule the
     model skims.
  4. A **dead doc link or a run-on archive entry**: a relative link that stopped
     resolving when its spec was archived one directory up, or a `**[DONE]`
     entry a merge left glued to the paragraph above it. HYG6 swept 88 of the
     first and HYG8 another 24; neither class shows up in a diff, which is why
     both were found by hand months later (HYG8 item 4).
  5. A **stale backlog index or an invalid task header**: `docs/backlog/INDEX.md`
     is generated from the header of every `tasks/<ID>.md` and union-merged on
     rebase, so a landing that skipped `scripts/backlog.py index` leaves it
     wrong in a way no diff reviewer reads 200 rows to notice (2026-10-26).

The first two are drift between prose and code, which is exactly what a human
reviewer stops noticing. The third is drift between a file's job and its size.
The fourth and fifth are drift between a document and the tree around it. This
script is the mechanical reader.

    python3 scripts/truth_fences.py            # all five fences
    python3 scripts/truth_fences.py config     # config keys only
    python3 scripts/truth_fences.py events     # event categories only
    python3 scripts/truth_fences.py claude     # CLAUDE.md size budget only
    python3 scripts/truth_fences.py links      # doc links + run-on entries only
    python3 scripts/truth_fences.py backlog    # task headers + INDEX.md freshness only
    python3 scripts/truth_fences.py blockers   # OBS7: main-thread blockers in view/controller files only
    python3 scripts/truth_fences.py env        # OBS6: every MP_* the daemon exports is read by the pipeline
    python3 scripts/truth_fences.py sources    # HYG15: no hand-rolled NSError(domain:); HYG18: the Core island's imports
    python3 scripts/truth_fences.py personal   # HYG21: roster names / library stems in tests and scripts (owner machine)

Stdlib only (tomllib, ast, re), so CI can run it without installing anything.

**The allowlists below are a ratchet, not an exemption.** Both are empty now,
which is the intended steady state: the fence landed with the then-known drift
listed and tagged with the task that owned it, and HYG2 (three dead knobs) and
DOC9 (eleven keys the example file never showed) emptied them by fixing what
they described. Anything not listed fails, and a stale entry fails too, so a
list can neither outlive its drift nor quietly absorb new drift. Add an entry
only for drift a named backlog task will clear, and expect to delete it soon.
"""
from __future__ import annotations

import ast
import importlib.util
import re
import sys
import tomllib
from pathlib import Path
from urllib.parse import unquote

REPO = Path(__file__).resolve().parents[1]

# --------------------------------------------------------------------------
# Allowlists (each entry names the task that removes it)
# --------------------------------------------------------------------------

# Documented but read by nothing, or read but documented nowhere. Anything not
# listed here is a failure.
# Empty, and that is the intended steady state: HYG2 cleared the three dead
# knobs and DOC9 the eleven keys `config.example.toml` never showed. A new entry
# here should be rare and short-lived.
CONFIG_ALLOWLIST: dict[str, str] = {}

# Parsed at runtime but deliberately never sourced from TOML, so the three
# documentation diffs skip them. Nothing else does (HYG18): each must still have a
# consumer (the dead-knob check), must still be parsed (else the entry is stale),
# and must not turn up in config.example.toml or the README (then it has become a
# TOML key and the exemption would be hiding its documentation checks).
CONFIG_NOT_FROM_TOML = {
    "modes.workflow_nda_mode": "resolved per-meeting from the workflow overlay, never a TOML key",
    "summarization.extra_sections": (
        "WF7: workflow-defined summary sections, arriving via the "
        "<stem>.meta.json overlay rather than the global config"
    ),
}

EVENT_ALLOWLIST: dict[str, str] = {}

# --------------------------------------------------------------------------
# Fence 3 budget: CLAUDE.md size
# --------------------------------------------------------------------------

# Bytes in one entry: a `- ` bullet or a `| ` table row. This is the real check,
# because it is the one that separates a **rule** from a **story** rather than
# punishing a file for having many legitimate rules.
#
# The two populations do not overlap, measured 2026-08-16 across all four files:
# a rule stated as one imperative line plus a link runs 160-680 bytes (daemon's
# 44 rules max at 376, the repo root's at 624, the Core island's at 672), while
# a bullet carrying its own incident narrative runs 1,100-3,300 (daemon before
# DOC14 split it: median 1,141, max 3,337; `pipeline/CLAUDE.md`'s shared-helper
# bullet is 3,296). 800 sits in the empty gap between them, so the fence fires
# on narrative and never on a rule.
CLAUDE_MAX_ENTRY_BYTES = 800

# Whole-file backstop, deliberately loose. With entries capped above, a file can
# only grow by accumulating rules, which is legitimate; this catches the far end
# of that, where the answer is to ask whether the subtree needs splitting rather
# than to write another line. The parenthetical here used to read "~85 rules at
# daemon's current average" and was measured before DOC14's split; daemon hit
# this cap at 58 rules on 2026-08-18, so the average it named had already
# drifted. A rule count is not derivable from a byte budget, which is why DOC15
# records both in its ship note rather than restating a ratio here.
CLAUDE_MAX_BYTES = 24_000

# Known drift, each naming the task that clears it. Same ratchet contract as the
# two lists above: an entry not listed fails, and a stale entry (a file now
# passing) fails too, so this cannot quietly absorb new growth.
# Empty, and that is the intended steady state: DOC14 split `daemon/CLAUDE.md`
# and `pipeline/CLAUDE.md` onto their `docs/gotchas.md` siblings, and both pass.
CLAUDE_ALLOWLIST: dict[str, str] = {}

# --------------------------------------------------------------------------
# Shared helpers
# --------------------------------------------------------------------------


class Fence:
    def __init__(self, name: str) -> None:
        self.name = name
        self.errors: list[str] = []

    def fail(self, msg: str) -> None:
        self.errors.append(msg)

    def report(self) -> bool:
        if not self.errors:
            print(f"  OK: {self.name}")
            return True
        for e in self.errors:
            print(f"::error::CI5 ({self.name}): {e}")
        return False


def _read(rel: str) -> str:
    return (REPO / rel).read_text(encoding="utf-8")


# --------------------------------------------------------------------------
# Fence 1: config keys
# --------------------------------------------------------------------------


def documented_example_keys() -> set[str]:
    """`section.key` for every key in config.example.toml.

    Live keys come from a real TOML parse, so a nested table cannot be mistaken
    for a key. Commented-out keys (`# local_adapter_path = ""`) are added on
    top: the file still shows the user that knob exists, which is documentation,
    and treating them as absent would report a documented opt-in as undocumented.
    """
    raw = _read("config.example.toml")
    doc = tomllib.loads(raw)
    keys = {
        f"{section}.{key}"
        for section, table in doc.items()
        if isinstance(table, dict)
        for key in table
    }

    section = ""
    for line in raw.splitlines():
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            section = stripped.strip("[]")
        elif section:
            commented = re.match(r"#\s*([a-z_]+)\s*=", stripped)
            if commented:
                keys.add(f"{section}.{commented.group(1)}")
    return keys


def documented_readme_keys() -> set[str]:
    """The README's config reference bullets. Two separator styles are in use
    (`- \\`key\\` - desc` and `- \\`key\\`: desc`), so match the backticked key
    alone."""
    body = _read("README.md")
    start = body.find("## Configuration reference")
    if start < 0:
        raise SystemExit("README.md has no '## Configuration reference' section")
    section = body[start:]
    end = section.find("\n## ", 1)
    if end > 0:
        section = section[:end]
    return set(re.findall(r"^- `([a-z_]+\.[a-z_]+)`", section, re.MULTILINE))


def _swift_alias_map(src: str) -> dict[str, str]:
    """`let rec = toml["recording"]?.table` -> {"rec": "recording"}. Derived from
    the source rather than hardcoded, so renaming an alias cannot silently
    orphan the extraction below."""
    return dict(
        re.findall(r'let\s+(\w+)\s*=\s*\w+\["([a-z_]+)"\]\?\.table', src)
    )


def swift_read_keys() -> set[str]:
    keys: set[str] = set()

    # ARCH9: the store is the one Swift reader of config.toml. `Config.swift`
    # used to be a second parse and a second extraction source here; it is now a
    # value the store produces, and `ConfigStoreFenceTests` keeps it that way.
    rel = "daemon/Sources/MeetingPipe/ConfigStore.swift"
    src = _read(rel)
    aliases = _swift_alias_map(src)
    if not aliases:
        raise SystemExit(f"{rel}: found no `let x = doc[\"section\"]?.table` aliases")
    for alias, key in re.findall(r'\b(\w+)\?\["([a-z_]+)"\]', src):
        if alias in aliases:
            keys.add(f"{aliases[alias]}.{key}")

    # ConfigStore's write-back carries the section name inline, and it must
    # agree with the read side or a saved Preferences change lands in the wrong
    # table.
    store = _read("daemon/Sources/MeetingPipe/ConfigStore.swift")
    written = {
        f"{section}.{key}"
        for section, key in re.findall(r'^\s*\("([a-z_]+)", "([a-z_]+)", ', store, re.MULTILINE)
    } | {
        # A direct write outside `modeledValues` (UX96 moved them all into it).
        f"{section}.{key}"
        for section, key in re.findall(r'ensureTable\("([a-z_]+)"(?:, in: \w+)?\)\["([a-z_]+)"\]', store)
    }
    if not written:
        raise SystemExit("ConfigStore.swift: found no modeledValues entries")
    keys |= written
    return keys


def python_read_keys() -> set[str]:
    """Pydantic models: `Config`'s fields name the sections, each annotation's
    class body names that section's keys."""
    tree = ast.parse(_read("pipeline/src/mp/config.py"))
    classes = {
        n.name: n for n in ast.walk(tree)
        if isinstance(n, ast.ClassDef)
    }
    config = classes.get("Config")
    if config is None:
        raise SystemExit("config.py: no `class Config`")

    keys: set[str] = set()
    sections = 0
    for stmt in config.body:
        if not (isinstance(stmt, ast.AnnAssign) and isinstance(stmt.target, ast.Name)):
            continue
        model = stmt.annotation
        if not isinstance(model, ast.Name) or model.id not in classes:
            continue
        sections += 1
        section = stmt.target.id
        for field in classes[model.id].body:
            if isinstance(field, ast.AnnAssign) and isinstance(field.target, ast.Name):
                name = field.target.id
                if not name.startswith("_") and name != "model_config":
                    keys.add(f"{section}.{name}")
    if sections < 5:
        raise SystemExit(f"config.py: only resolved {sections} sections; extractor is stale")
    return keys


def _camel(key: str) -> str:
    head, *rest = key.split("_")
    return head + "".join(w.capitalize() for w in rest)


def _reader_helpers(src: str, aliases: dict[str, str]) -> dict[str, str]:
    """`func seconds(...) { ... det?[key] ... }` -> {"seconds": "detection"}.

    A parse does not have to be written inline. `ConfigStore` reads its four
    seconds knobs through one local helper (TOML separates int from float
    literals and TOMLKit will not coerce, so each needs both branches), and a
    property-name map that only understood the inline subscript form silently
    lost those entries. The helper's own body names the table alias, so the
    section is still derived from source rather than hardcoded.
    """
    out: dict[str, str] = {}
    # Matched from every `func` rather than with one `findall`: the helper is
    # nested inside the store's `apply` (ARCH9), and a non-overlapping scan
    # consumed it as part of the enclosing method's body and never saw its name.
    shape = re.compile(r"func\s+(\w+)\s*\([^)]*\)[^{]*\{(.*?)\n        \}", re.S)
    for start in re.finditer(r"\bfunc\s", src):
        match = shape.match(src, start.start())
        if match is None:
            continue
        name, body = match.groups()
        for alias in re.findall(r"\b(\w+)\?\[\s*key\s*\]", body):
            if alias in aliases and name not in out:
                out[name] = aliases[alias]
    return out


def configstore_properties() -> dict[str, str]:
    """`self.<prop> = <alias>["<key>"]`, or `self.<prop> = <helper>("<key>", …)`,
    -> {"section.key": "prop"}. The map matters for any key whose TOML name and
    Swift property disagree (`mic_only_silence_seconds` -> `micOnlySilenceSec`,
    kept for back-compat), since `_camel` alone cannot bridge those."""
    src = _read("daemon/Sources/MeetingPipe/ConfigStore.swift")
    aliases = _swift_alias_map(src)
    out: dict[str, str] = {}
    for prop, alias, key in re.findall(
        r'self\.(\w+)\s*=\s*\(?\s*(\w+)\?\["([a-z_]+)"\]', src
    ):
        if alias in aliases:
            out[f"{aliases[alias]}.{key}"] = prop

    helpers = _reader_helpers(src, aliases)
    for prop, helper, key in re.findall(r'self\.(\w+)\s*=\s*(\w+)\("([a-z_]+)"', src):
        if helper in helpers:
            out[f"{helpers[helper]}.{key}"] = prop
    return out


def unconsumed_keys(read: set[str]) -> list[str]:
    """Keys that are parsed and then never read by anything.

    This is the dead-knob class (HYG2, and END4(b) before it), and it is the one
    a documented-versus-parsed diff structurally cannot see: a dead knob IS
    parsed, persisted, and rendered, which is exactly why it looks alive. The
    signal is that nothing ever reads the property the parse lands in.

    Deliberately conservative, because a false positive here sends someone to
    delete a live setting:
      - Only reads through a CONFIG receiver count (`configStore?.x`,
        `cfg.recording.x`), because a bare `.x` collides constantly: `.sampleRate`
        appears on every `AVAudioFormat` in the recorder and would fake a
        consumer for `recording.sample_rate` forever.
      - Assignments do not count. `config.sampleRate = 48000` on a ScreenCaptureKit
        config object is a write to someone else's type, not a read of ours.
      - The Preferences UI is excluded: rendering a control for a knob is what
        makes a dead one convincing, not evidence it drives anything.
      - The config files themselves are NOT excluded, because the receiver rule
        already skips their parse and write-back lines (those use TOML
        subscripts and bare identifiers, not `cfg.x`), while `config.py`'s
        derived predicates ARE real consumers: `zero_egress` reading
        `cfg.modes.workflow_nda_mode` is the only thing keeping that key alive.
      - A key consumed in EITHER tree is alive.
    """
    props = configstore_properties()
    sources = [
        p for p in sorted((REPO / "daemon" / "Sources").rglob("*.swift"))
        if "/Preferences/" not in str(p)
    ] + sorted((REPO / "pipeline" / "src" / "mp").rglob("*.py"))
    blob = "\n".join(p.read_text(encoding="utf-8") for p in sources)

    dead: list[str] = []
    for key in sorted(read):
        section, _, leaf = key.partition(".")
        names = {leaf, _camel(leaf)}
        if key in props:
            names.add(props[key])
        # `<config receiver>[?].[<section>.]<name>`, not an assignment.
        # The `_?` matters: publishers hold the config as `self._cfg`, and a
        # plain `\b` will not match inside `_cfg` because `_` is a word char.
        pattern = "|".join(
            rf"(?<![A-Za-z0-9])_?(?:config|configStore|cfg|conf)\??\."
            rf"(?:{re.escape(section)}\.)?{re.escape(n)}\b(?!\s*=[^=])"
            for n in sorted(names)
        )
        if not re.search(pattern, blob):
            dead.append(key)
    return dead


def check_config() -> bool:
    fence = Fence("config keys")

    example = documented_example_keys()
    readme = documented_readme_keys()
    documented = example | readme
    read = swift_read_keys() | python_read_keys()

    # Guard the guard: an extractor that silently stops matching would make both
    # diffs vacuously empty and the fence permanently green.
    if len(documented) < 25:
        fence.fail(f"only extracted {len(documented)} documented keys; the extractor is stale")
    if len(read) < 25:
        fence.fail(f"only extracted {len(read)} read keys; the extractor is stale")
    if fence.errors:
        return fence.report()

    known = set(CONFIG_ALLOWLIST) | set(CONFIG_NOT_FROM_TOML)
    drift: set[str] = set()

    for key in sorted(documented - read):
        drift.add(key)
        if key in known:
            continue
        fence.fail(
            f"`{key}` is documented but no reader parses it. Wire it, delete it, or, "
            "if it is genuinely owed to a backlog task, add it to CONFIG_ALLOWLIST "
            "with that task id."
        )

    for key in sorted(read - documented):
        drift.add(key)
        if key in known:
            continue
        fence.fail(
            f"`{key}` is parsed at runtime but documented nowhere. Add it to "
            "config.example.toml (and the README reference if it is user-facing)."
        )

    # config.example.toml is the file every doc points at as THE reference, so a
    # key the README documents but the example file omits is a user who copies
    # the example and never learns the knob exists. This is the axis that made
    # the sink sections invisible.
    for key in sorted(readme - example):
        drift.add(key)
        if key in known:
            continue
        fence.fail(
            f"`{key}` is in the README config reference but not in "
            "config.example.toml. The example file is what users copy; add it "
            "there too (commented out is fine for an opt-in)."
        )

    # Only CONFIG_ALLOWLIST exempts a dead knob. A key resolved from the overlay
    # rather than TOML still needs a consumer (HYG18).
    for key in unconsumed_keys(read):
        drift.add(key)
        if key in CONFIG_ALLOWLIST:
            continue
        fence.fail(
            f"`{key}` is a DEAD KNOB: parsed and persisted, and nothing ever reads "
            "the value. This is the END4(b) class, where a live Preferences control "
            "drives nothing. Wire it to a consumer or delete it end to end."
        )

    # A stale allowlist is drift of its own: it would silently exempt a future
    # key that reuses the name.
    for key, reason in sorted(CONFIG_ALLOWLIST.items()):
        if key not in drift:
            fence.fail(
                f"CONFIG_ALLOWLIST entry `{key}` ({reason}) no longer describes real "
                "drift. The task that owned it has landed; delete the line."
            )

    # HYG18: the same ratchet for the not-from-TOML exemption, which had none.
    for key, reason in sorted(CONFIG_NOT_FROM_TOML.items()):
        if key not in read:
            fence.fail(
                f"CONFIG_NOT_FROM_TOML entry `{key}` ({reason}) is no longer parsed by "
                "either reader. Delete the entry."
            )
        if key in documented:
            fence.fail(
                f"CONFIG_NOT_FROM_TOML entry `{key}` is documented in config.example.toml "
                "or the README, so it is a TOML key now. Delete the entry and let the "
                "documentation checks see it."
            )

    return fence.report()


# --------------------------------------------------------------------------
# Fence 2: event categories and action names
# --------------------------------------------------------------------------

# OBS1: `Log.failure(` writes an event row too, so its category and action are fenced alike.
# OBS9: `Log.diagnostic(` and `.emitDiagnostic(` write `diagnostics.jsonl`, same envelope.
SWIFT_EMIT = re.compile(r'(?:Log\.event|Log\.failure|Log\.diagnostic|\.emit|\.emitDiagnostic)\(\s*category:\s*"([a-z_]+)"')
# Scoped to the emit call, NOT a bare `action:` label: `LibraryError.noTranscript`
# also takes an `action:` and its value is a human sentence ("re-run"), which a
# loose regex reports as a convention violation forever.
SWIFT_EMIT_ACTION = re.compile(
    r'(?:Log\.event|Log\.failure|Log\.diagnostic|\.emit|\.emitDiagnostic)\(\s*category:\s*"[a-z_]+",\s*action:\s*([^\n]*?),\s*(?:attributes|error|reason):'
)
STRING_LITERAL = re.compile(r'"([^"\\]*)"')
# Python's `events.emit("category", "action", ...)`, tolerating a newline after
# the paren: two real call sites wrap, and a single-line regex misses both.
PY_EMIT = re.compile(r'events\.emit\(\s*\n?\s*"([a-z_]+)"')
SNAKE = re.compile(r"^[a-z][a-z0-9_]*$")


def documented_categories() -> dict[str, set[str]]:
    """The CONVENTIONS.md '### Categories' table, as {source: {category}}."""
    body = _read("CONVENTIONS.md")
    # Anchor on the heading LINE, not the first occurrence of the text: prose
    # elsewhere in the file refers to "the `### Categories` table" by name, and
    # a plain `find` locks onto that mention and then parses no table at all.
    heading = re.search(r"^### Categories$", body, re.MULTILINE)
    if heading is None:
        raise SystemExit("CONVENTIONS.md has no '### Categories' heading")
    section = body[heading.start() : heading.start() + 2000]

    out: dict[str, set[str]] = {}
    for line in section.splitlines():
        if not line.startswith("|") or "---" in line:
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) != 2 or cells[0] == "Source":
            continue
        key = "daemon" if "Daemon" in cells[0] else "pipeline" if "Pipeline" in cells[0] else None
        if key:
            out[key] = set(re.findall(r"`([a-z_]+)`", cells[1]))
    if set(out) != {"daemon", "pipeline"}:
        raise SystemExit(f"CONVENTIONS.md category table parsed as {sorted(out)}; expected both rows")
    return out


def _swift_sources() -> list[Path]:
    return [
        p for p in sorted((REPO / "daemon" / "Sources").rglob("*.swift"))
        # Logger.swift constructs `os.Logger(subsystem:category:)`, which is not
        # an event emission and would inject false positives.
        if p.name != "Logger.swift"
    ]


def emitted_categories() -> dict[str, set[str]]:
    daemon: set[str] = set()
    for path in _swift_sources():
        daemon |= set(SWIFT_EMIT.findall(path.read_text(encoding="utf-8")))

    pipeline: set[str] = set()
    for path in sorted((REPO / "pipeline" / "src" / "mp").rglob("*.py")):
        pipeline |= set(PY_EMIT.findall(path.read_text(encoding="utf-8")))

    return {"daemon": daemon, "pipeline": pipeline}


def non_snake_actions() -> list[tuple[str, int, str]]:
    """CONVENTIONS.md: "Use snake_case for the action". A dotted or camelCase
    action breaks the convention every `mp logs` / `mp analyze-detection` filter
    reads by."""
    out: list[tuple[str, int, str]] = []
    for path in _swift_sources():
        src = path.read_text(encoding="utf-8")
        for match in SWIFT_EMIT_ACTION.finditer(src):
            expr = match.group(1)
            # A bare variable or an interpolation is a runtime value with no
            # literal to check; a ternary has two literals and both count.
            for action in STRING_LITERAL.findall(expr):
                if SNAKE.match(action):
                    continue
                line = src.count("\n", 0, match.start()) + 1
                out.append((str(path.relative_to(REPO)), line, action))
    return out


# SEC38: attribute keys that carry meeting content (a window or meeting title, a
# published note's path or page address, which embeds the title slug). The event
# log is handed to analysis sessions as a diagnostics pack, so a row carries a
# shape class or a sink name instead. `previous` is deliberately absent: many rows
# use it for a non-title value, so `window_title_changed`'s is pinned by its test.
CONTENT_KEY_DENYLIST = ("title", "titles", "candidate_titles", "page_url", "note_path", "meeting_title")
# Keys that look like content and are not, with the reason (SEC38's filing-time
# correction). A new entry needs the same kind of reason.
CONTENT_KEY_ALLOWLIST: dict[str, str] = {
    "display_name": "the app's localizedName (MeetingSourceScanner), not a meeting's",
    "ax_label": "the mute button's accessibility label (MicGate.attributes(for:))",
    "label": "the mute button's AX label, or the diarizer's cluster label; a typed speaker name is never logged",
}
# Interpolations a daemon.log line may not carry.
WRITELINE_DENYLIST = ("meetingTitle", "pageURL")

SWIFT_EMIT_CALL = re.compile(r"(?:Log\.event|Log\.failure|Log\.diagnostic|\.emit|\.emitDiagnostic)\(\s*category:")
SWIFT_ATTR_ASSIGN = re.compile(r'attributes\["([a-z_]+)"\]\s*=')
PY_EMIT_CALL = re.compile(r"events\.emit\(")
WRITELINE_CALL = re.compile(r"Log\.writeLine\(")


SWIFT_ATTR_LITERAL = re.compile(r":\s*\[String:\s*Any\]\s*=\s*\[")


def _denied(key: str) -> bool:
    """A denylisted key, or any `*_title` / `*_titles` (END28's `from_title` was both)."""
    return key in CONTENT_KEY_DENYLIST or key.endswith(("_title", "_titles"))


def _call_span(src: str, open_paren: int, pair: str = "()") -> str:
    """The text from an opening bracket to its balanced close."""
    depth = 0
    for i in range(open_paren, len(src)):
        if src[i] == pair[0]:
            depth += 1
        elif src[i] == pair[1]:
            depth -= 1
            if depth == 0:
                return src[open_paren : i + 1]
    return src[open_paren:]


def content_key_hits(swift: dict[str, str], python: dict[str, str]) -> list[str]:
    """`path:line: why` for every denied key in an emit call or a daemon.log line. Pure."""
    out: list[str] = []
    dict_key = re.compile(r'(?:^|[\[,])\s*"([a-z_]+)"\s*:', re.MULTILINE)

    def line_of(src: str, pos: int) -> int:
        return src.count("\n", 0, pos) + 1

    for path, src in swift.items():
        for m in SWIFT_EMIT_CALL.finditer(src):
            span = _call_span(src, m.start() + m.group(0).index("("))
            # A dictionary key follows `[`, `,` or a line start; a ternary's `? "x" :` is a value.
            for key in dict_key.findall(span):
                if _denied(key):
                    out.append(f"{path}:{line_of(src, m.start())}: event attribute `{key}`")
        # An attributes dictionary built before the call (`var attributes: [String: Any] = [...]`).
        for m in SWIFT_ATTR_LITERAL.finditer(src):
            for key in dict_key.findall(_call_span(src, m.end() - 1, "[]")):
                if _denied(key):
                    out.append(f"{path}:{line_of(src, m.start())}: event attribute `{key}`")
        for m in SWIFT_ATTR_ASSIGN.finditer(src):
            if _denied(m.group(1)):
                out.append(f"{path}:{line_of(src, m.start())}: event attribute `{m.group(1)}`")
        for m in WRITELINE_CALL.finditer(src):
            span = _call_span(src, m.end() - 1)
            for name in WRITELINE_DENYLIST:
                if re.search(r"\\\([^)]*\b" + name + r"\b", span):
                    out.append(f"{path}:{line_of(src, m.start())}: daemon log line interpolates `{name}`")
    for path, src in python.items():
        for m in PY_EMIT_CALL.finditer(src):
            span = _call_span(src, m.end() - 1)
            for key in re.findall(r"\b([a-z_]+)\s*=(?!=)", span):
                if _denied(key):
                    out.append(f"{path}:{line_of(src, m.start())}: event attribute `{key}`")
    return out


def check_events() -> bool:
    fence = Fence("event categories")

    documented = documented_categories()
    emitted = emitted_categories()

    if len(emitted["daemon"]) < 10:
        fence.fail(f"only found {len(emitted['daemon'])} daemon categories; the extractor is stale")
    if not emitted["pipeline"]:
        fence.fail("found no pipeline categories; the extractor is stale")
    if fence.errors:
        return fence.report()

    for source in ("daemon", "pipeline"):
        for category in sorted(emitted[source] - documented[source] - set(EVENT_ALLOWLIST)):
            fence.fail(
                f"category `{category}` is emitted by the {source} but absent from the "
                "CONVENTIONS.md '### Categories' table. Add it there, or use an "
                "existing category."
            )

    # A documented category nothing emits is the mirror drift: it sends a reader
    # looking for events that do not exist.
    for source in ("daemon", "pipeline"):
        for category in sorted(documented[source] - emitted[source]):
            fence.fail(
                f"category `{category}` is documented for the {source} but nothing emits "
                "it. Remove the row entry, or restore the emitter."
            )

    swift_src = {str(p.relative_to(REPO)): p.read_text(encoding="utf-8") for p in _swift_sources()}
    py_src = {
        str(p.relative_to(REPO)): p.read_text(encoding="utf-8")
        for p in sorted((REPO / "pipeline" / "src" / "mp").rglob("*.py"))
    }
    for hit in content_key_hits(swift_src, py_src):
        fence.fail(
            f"{hit} carries meeting content into a log (SEC38). Log a shape class "
            "(`WindowTitleShape`), the sink names, or a count instead."
        )

    for path, line, action in non_snake_actions():
        fence.fail(
            f"{path}:{line}: action `{action}` is not snake_case. CONVENTIONS.md "
            "'Adding a new action' requires snake_case (`recording_started`, not "
            "`RecordingStarted` and not `toolbar.action`)."
        )

    return fence.report()


# --------------------------------------------------------------------------
# Fence 3: CLAUDE.md size budget
# --------------------------------------------------------------------------


def claude_files() -> list[Path]:
    """Every CLAUDE.md this repo owns.

    Skips `.build/` (checked-out dependencies carry their own, and FluidAudio's
    is not ours to shrink) and `.claude/worktrees/` (a parallel session's copy of
    the same files, which would double-report every finding).
    """
    skip = (".build", ".claude/worktrees", "node_modules", ".git")
    out = []
    for path in sorted(REPO.rglob("CLAUDE.md")):
        rel = path.relative_to(REPO).as_posix()
        if any(part in rel for part in skip):
            continue
        out.append(path)
    return out


def check_claude() -> bool:
    fence = Fence("CLAUDE.md budget")

    found = claude_files()
    if len(found) < 3:
        fence.fail(f"only found {len(found)} CLAUDE.md files; the walker is stale")
        return fence.report()

    def offenders(path: Path) -> tuple[list[tuple[int, int, str]], int]:
        """Over-long entries as (line no, bytes, text), plus the whole-file size."""
        raw = path.read_bytes()
        over = []
        for n, line in enumerate(raw.decode("utf-8").splitlines(), start=1):
            if not (line.startswith(("- ", "| "))):
                continue
            size = len(line.encode("utf-8"))
            if size > CLAUDE_MAX_ENTRY_BYTES:
                over.append((n, size, line))
        return over, len(raw)

    seen: set[str] = set()
    for path in found:
        rel = path.relative_to(REPO).as_posix()
        over, size = offenders(path)
        seen.add(rel)

        if not over and size <= CLAUDE_MAX_BYTES:
            continue
        if rel in CLAUDE_ALLOWLIST:
            print(f"  allowed: {rel}, {len(over)} long entries at {size:,}B ({CLAUDE_ALLOWLIST[rel]})")
            continue

        for n, entry_size, line in over:
            fence.fail(
                f"{rel}:{n}: entry is {entry_size:,} bytes, over the "
                f"{CLAUDE_MAX_ENTRY_BYTES:,} limit. That length is narrative, not a rule, "
                "and this file is prepended to every prompt in its subtree. Move the "
                "evidence to the sibling `docs/gotchas.md` and leave one imperative line "
                f"plus a link: {line[:70]}..."
            )
        if size > CLAUDE_MAX_BYTES:
            fence.fail(
                f"{rel} is {size:,} bytes (~{size // 4:,} tokens), over the "
                f"{CLAUDE_MAX_BYTES:,} backstop. Every entry may be a fair rule and there "
                "are still too many to read on every turn; consider whether this subtree "
                "wants splitting. Raising CLAUDE_MAX_BYTES is not the fix."
            )

    # A stale allowlist entry is drift too: it says a file is failing when it is
    # not, so the next reader trusts a ratchet that has already been released.
    for rel, why in sorted(CLAUDE_ALLOWLIST.items()):
        if rel not in seen:
            fence.fail(f"allowlist names `{rel}`, which does not exist. Remove the entry ({why}).")
            continue
        over, size = offenders(REPO / rel)
        if not over and size <= CLAUDE_MAX_BYTES:
            fence.fail(
                f"`{rel}` now passes. Delete its CLAUDE_ALLOWLIST entry ({why}); "
                "the ratchet only moves one way."
            )

    return fence.report()


# --------------------------------------------------------------------------
# Fence 4: doc links and run-on archive entries (HYG8 item 4)
# --------------------------------------------------------------------------
#
# The mode is called `links` because that is the name HYG8's acceptance pins,
# but it carries two checks. Both are archive-hygiene failures that a diff
# cannot show you, and both have recurred often enough to be worth mechanising:
#
#   1. A **dead relative link**. Archiving a task moves its spec up one
#      directory and nothing rewrites the `../` levels inside it, so every
#      archived body silently loses one level on the way up. HYG6 swept 88 of
#      these out of `q6-final.md` on 2026-08-18 (47 of them the backlog
#      back-link alone, against 4 that were spelled right) and HYG8 another 24.
#      The repair is mechanical; the noticing is what keeps failing.
#   2. A **run-on `[DONE]` entry**. A `**[DONE] ...**` line is a bold
#      paragraph, not a heading, so if a both-sides-add merge leaves it
#      adjacent to the previous entry's closing line with no blank between,
#      markdown renders the two as one paragraph. UX72 found it in
#      `q6-final.md`, FEAT15 hit the same seam in `daemon/docs/gotchas.md`, and
#      neither was visible in a diff with no conflict markers left in it.
#
# Two skips are non-negotiable, and both are demonstrated by real content in
# this tree rather than imagined:
#
#   * **Non-file URL schemes.** `meetingpipe://` appears in `q6-final.md` and
#     `CONVENTIONS.md` as documentation of the app's own deeplink. Flagging it
#     produces a false positive that gets suppressed by hand, and a suppression
#     list is the thing that rots next.
#   * **Inline code spans and fenced blocks.** `DOC13.md` quotes four of
#     `docs/GUIDE.md`'s links, `HYG7.md` quotes END9's broken
#     `PromptEndPolicy.swift#L7`, and `HYG8.md` quotes `DET12.md`'s `DET11.md`.
#     Quoting a broken link is *how a spec records that a link is broken*, so a
#     fence that fails on it makes that entire class of finding unwriteable.
#     A fence that fires on correct prose is worse than no fence.

_FENCE_DELIM_RE = re.compile(r"^\s*(?:```|~~~)")
_INLINE_CODE_RE = re.compile(r"``[^`]*``|`[^`]*`")
_LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)")
_SCHEME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9+.\-]*:")
_DONE_RE = re.compile(r"^\*\*\[DONE\]")
_BOLD_LINE_RE = re.compile(r"^\*\*")
_LIST_ITEM_RE = re.compile(r"^\s*(?:[-*+]|\d+\.)\s")

# Directories that are not the repo's documentation: vendored trees, build
# output, and the per-session worktrees, whose copies would double every
# finding under a path nobody edits.
_LINK_SKIP_DIRS = {".git", ".claude", ".build", ".venv", "node_modules", "__pycache__"}


def strip_code(text: str) -> str:
    """Blank out fenced blocks and inline code spans, preserving line count.

    Line count is preserved rather than the text compacted, so a finding can
    still name the line it is on.
    """
    out: list[str] = []
    in_fence = False
    for line in text.splitlines():
        if _FENCE_DELIM_RE.match(line):
            in_fence = not in_fence
            out.append("")
            continue
        out.append("" if in_fence else _INLINE_CODE_RE.sub("", line))
    return "\n".join(out)


def markdown_links(text: str) -> list[tuple[int, str]]:
    """Every inline `[text](target)` outside code, as (line number, target)."""
    found: list[tuple[int, str]] = []
    for n, line in enumerate(strip_code(text).splitlines(), start=1):
        found.extend((n, m.group(1)) for m in _LINK_RE.finditer(line))
    return found


def resolve_link(base: Path, target: str) -> Path | None:
    """The path a relative link points at, or None when it is not ours to check.

    None covers the three cases that are correct as written: a URL with a
    scheme (`https:`, `mailto:`, and the app's own `meetingpipe://`), a bare
    in-page anchor, and an empty target.
    """
    if _SCHEME_RE.match(target) or target.startswith(("#", "//")):
        return None
    path = unquote(target.split("#", 1)[0].split("?", 1)[0]).strip()
    if not path:
        return None
    return base / path


def run_on_lines(text: str) -> list[int]:
    """Line numbers where a bold paragraph ran on into the block above it.

    Two shapes, because a `**bold**` line is a paragraph and never a heading:

      * a `**[DONE]` archive entry with any non-blank line above it, which is
        the UX72 merge artifact this check was written for, and
      * any bold line directly under a **list item**, which markdown swallows as
        a lazy continuation of that item.

    The second is deliberately narrower than the first. "Bold line under any
    non-blank line" would fire on every legitimate bold lead-in mid-paragraph;
    restricted to list items it measured **one** hit across 231 files on
    2026-08-19, and that hit was a real defect (DSN30's own item 2 answer,
    rendering inside the bullet above it, added the previous day).
    """
    lines = text.splitlines()
    found: list[tuple[int, str]] = []
    for n, line in enumerate(lines, start=1):
        if n == 1 or not _BOLD_LINE_RE.match(line):
            continue
        previous = lines[n - 2]
        if not previous.strip():
            continue
        if _LIST_ITEM_RE.match(previous):
            found.append((n, "the list item above it, which swallows it as a continuation of that item"))
        elif _DONE_RE.match(line):
            found.append((n, "the entry above it, which markdown renders as one run-on paragraph"))
    return found


def doc_files() -> list[Path]:
    return sorted(
        p
        for p in REPO.rglob("*.md")
        if not (_LINK_SKIP_DIRS & set(p.relative_to(REPO).parts))
    )


def check_links() -> bool:
    fence = Fence("doc links")

    files = doc_files()
    # Staleness guard, matching the other three fences: a walker that stops
    # finding the tree passes silently, which is the one failure a fence must
    # never have.
    if len(files) < 50:
        fence.fail(f"only found {len(files)} markdown files; the walker is stale")
        return fence.report()

    for path in files:
        text = path.read_text(encoding="utf-8")
        rel = path.relative_to(REPO)
        for n, target in markdown_links(text):
            resolved = resolve_link(path.parent, target)
            if resolved is not None and not resolved.exists():
                fence.fail(
                    f"{rel}:{n} links to `{target}`, which does not resolve. "
                    "Archiving a spec moves it up one directory and every `../` "
                    "inside it loses a level; fix the level, or drop the link and "
                    "keep the file name as text."
                )
        for n, why in run_on_lines(text):
            fence.fail(
                f"{rel}:{n} starts a bold paragraph with no blank line separating it from "
                f"{why}. Add the blank line."
            )

    return fence.report()


# --------------------------------------------------------------------------
# Fence 5: the generated backlog index
# --------------------------------------------------------------------------


def check_backlog() -> bool:
    fence = Fence("backlog index")
    # `scripts/backlog.py` owns the header contract and the renderer; this
    # fence only runs its check, so the two can never disagree about it.
    spec = importlib.util.spec_from_file_location("backlog", REPO / "scripts" / "backlog.py")
    assert spec and spec.loader
    backlog = importlib.util.module_from_spec(spec)
    sys.modules["backlog"] = backlog
    spec.loader.exec_module(backlog)
    for error in backlog.check():
        fence.fail(error)
    return fence.report()


# --------------------------------------------------------------------------
# Fence 6 (OBS7 "Fence B"): main-thread blockers in view and controller files
# --------------------------------------------------------------------------

# A synchronous wait or a blocking disk read in a view, window, pane, controller or menu builder
# runs on the main thread unless something moved it, and the responsiveness audit
# (2026-11-13) found the freezes in exactly those files. These patterns are textual: they
# cannot see which thread a call lands on, so every hit is either removed or listed below with
# the reason it is acceptable. A new hit fails the fence from the day it appears.
BLOCKER_PATTERNS = {
    "waitUntilExit": re.compile(r"\.waitUntilExit\("),
    "DispatchQueue.main.sync": re.compile(r"DispatchQueue\.main\.sync\b"),
    "semaphore/group wait": re.compile(r"\.wait\("),
    "Data(contentsOf:)": re.compile(r"\bData\(contentsOf:"),
    "contentsOfDirectory": re.compile(r"\bcontentsOfDirectory\b"),
}
# What "view and controller files" means, relative to `daemon/Sources/MeetingPipe`.
BLOCKER_GLOBS = ("*View*.swift", "*Window*.swift", "*Controller*.swift", "*Pane*.swift", "*Menu*.swift")

# (path relative to daemon/Sources/MeetingPipe, pattern name) -> (exact hit count, reason).
# The count is exact on purpose: a second site in an allowlisted file fails rather than
# riding on the first one's reason, and a listed site that was removed fails as stale.
BLOCKER_ALLOWLIST: dict[tuple[str, str], tuple[int, str]] = {
    ("DigestsView.swift", "contentsOfDirectory"): (
        1, "DigestFile.scan, called only from a Task.detached in the digest reload"),
    ("MeetingDetailView.swift", "Data(contentsOf:)"): (
        2, "PublishURLs.notion/obsidian, called only from the Task.detached in reloadPublishURLs"),
    ("Preferences/PreferencesView+Pipeline.swift", "waitUntilExit"): (
        1, "off main inside the Task.detached of the prompt preview's load(), but that closure blocks "
           "a cooperative-pool thread, which daemon/CLAUDE.md forbids; CONC5's ProcessRunner "
           "replaces it, and this entry goes with that task"),
}


def _code_only(line: str) -> str:
    """`line` without its `//` comment, leaving `//` inside a string literal alone."""
    in_string = False
    i = 0
    while i < len(line):
        ch = line[i]
        if ch == "\\" and in_string:
            i += 2
            continue
        if ch == '"':
            in_string = not in_string
        elif not in_string and line.startswith("//", i):
            return line[:i]
        i += 1
    return line


def _swift_code_lines(text: str) -> list[str]:
    """`text`'s lines with `//` and `/* */` comments blanked, one entry per source line, so a
    line number survives and a doc comment quoting a forbidden form does not count."""
    out: list[str] = []
    in_block_comment = False
    for raw in text.splitlines():
        line = raw
        if in_block_comment:
            if "*/" not in line:
                out.append("")
                continue
            line = line.split("*/", 1)[1]
            in_block_comment = False
        line = re.sub(r"/\*.*?\*/", "", line)
        if "/*" in line:
            in_block_comment = True
            line = line.split("/*", 1)[0]
        out.append(_code_only(line))
    return out


def blocker_hits(root: Path) -> dict[tuple[str, str], list[int]]:
    """{(relative path, pattern name): [line numbers]} for every view/controller file under `root`."""
    files: set[Path] = set()
    for glob in BLOCKER_GLOBS:
        files |= set(root.rglob(glob))
    hits: dict[tuple[str, str], list[int]] = {}
    for path in sorted(files):
        rel = path.relative_to(root).as_posix()
        for number, code in enumerate(_swift_code_lines(path.read_text(encoding="utf-8")), start=1):
            for name, pattern in BLOCKER_PATTERNS.items():
                if pattern.search(code):
                    hits.setdefault((rel, name), []).append(number)
    return hits


def check_blockers(
    root: Path | None = None,
    allowlist: dict[tuple[str, str], tuple[int, str]] | None = None,
) -> bool:
    fence = Fence("main-thread blockers")
    root = root if root is not None else REPO / "daemon" / "Sources" / "MeetingPipe"
    allowlist = BLOCKER_ALLOWLIST if allowlist is None else allowlist
    hits = blocker_hits(root)

    for key, (count, reason) in sorted(allowlist.items()):
        if not reason.strip():
            fence.fail(f"allowlist entry {key[0]} / {key[1]} has no reason")
        found = len(hits.get(key, []))
        if found == 0:
            fence.fail(f"allowlist entry {key[0]} / {key[1]} is stale: the listed site is gone. Delete the entry.")
        elif found != count:
            fence.fail(
                f"{key[0]}: {found} `{key[1]}` site(s) where the allowlist expects {count}. "
                "Move the new one off main, or update the entry with its reason."
            )
    for (rel, name), lines in sorted(hits.items()):
        if (rel, name) in allowlist:
            continue
        where = ", ".join(f"{rel}:{n}" for n in lines)
        fence.fail(
            f"`{name}` in a view or controller file ({where}). It blocks the main thread unless "
            "something moved it off: move it, or allowlist it in BLOCKER_ALLOWLIST with the reason."
        )
    return fence.report()


# --------------------------------------------------------------------------
# Fence (HYG15, HYG18): source rules under daemon/Sources that a grep can hold
# --------------------------------------------------------------------------

# CONVENTIONS.md "Error propagation": never `NSError(domain:code:userInfo:)`, since a hand-rolled
# domain and `code: 1` carry nothing a caller can branch on; each subsystem names its failures in a
# nested `LocalizedError`. Matched across line breaks, comments stripped, so a doc comment quoting
# the old form does not count.
NSERROR_CONSTRUCTION = re.compile(r'\bNSError\(\s*domain:\s*(?:"([^"\\]*)"|([A-Za-z_][\w.]*))')

# (path relative to the repo, domain: the string literal, or the identifier for an Apple constant)
# -> (exact count, reason). Exact for the same reason as BLOCKER_ALLOWLIST: a new site fails rather
# than riding on a listed one's reason, and a listed site that is gone fails as stale.
NSERROR_ALLOWLIST: dict[tuple[str, str], tuple[int, str]] = {
    ("daemon/Sources/MeetingPipe/PipelineLauncher.swift", "PipelineDriver"): (
        18, "the PipelineDriver protocol's default stubs; A7 in ARCH5 removes the defaults, and this "
            "entry with them"),
    ("daemon/Sources/MeetingPipe/HotkeyManager.swift", "NSOSStatusErrorDomain"): (
        1, "a Carbon OSStatus carried in Apple's own domain, so Log.failure's error_domain and "
           "error_code name the real status; not an invented domain"),
}


def nserror_hits(repo: Path) -> dict[tuple[str, str], list[int]]:
    """{(path relative to `repo`, domain): [line numbers]} for every `NSError(domain:` construction
    under `repo/daemon/Sources`. Pure apart from reading the files."""
    hits: dict[tuple[str, str], list[int]] = {}
    for path in sorted((repo / "daemon" / "Sources").rglob("*.swift")):
        rel = path.relative_to(repo).as_posix()
        code = "\n".join(_swift_code_lines(path.read_text(encoding="utf-8")))
        for match in NSERROR_CONSTRUCTION.finditer(code):
            domain = match.group(1) if match.group(1) is not None else match.group(2)
            hits.setdefault((rel, domain), []).append(code.count("\n", 0, match.start()) + 1)
    return hits


# HYG18: the MeetingPipeCore island rules (`daemon/Sources/MeetingPipeCore/CLAUDE.md`), which held
# with nothing failing if they stopped. Every module Core may import; SwiftUI is deliberately absent.
CORE_IMPORT_ALLOWLIST = frozenset({
    "Foundation", "ApplicationServices", "CoreAudio", "os", "TOMLKit", "ScreenCaptureKit", "CoreGraphics",
    "AppKit",
})
# The one file allowed `import AppKit`: NSWorkspace's termination notification and NSRunningApplication
# KVO have no Foundation equivalent.
CORE_APPKIT_FILE = "daemon/Sources/MeetingPipeCore/Lifecycle/Signals/WorkspaceSignal.swift"
# `import X`, `@preconcurrency import X`, `import struct X.Y`, `import os.log`: the top-level module.
SWIFT_IMPORT = re.compile(
    r"^\s*(?:@\w+\s+)*import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?([A-Za-z_]\w*)",
    re.M,
)
CORE_TARGET = re.compile(r'\.target(\()\s*name:\s*"MeetingPipeCore"')
# `targeted` or stricter, so CONC6 raising it to `complete` does not trip the fence.
CORE_STRICT_CONCURRENCY = re.compile(r'"-strict-concurrency=(?:targeted|complete)"')
CORE_ONLY_DEPENDENCY = '.product(name:"TOMLKit",package:"TOMLKit")'


def island_failures(repo: Path) -> list[str]:
    """Every way `repo`'s MeetingPipeCore breaks its island rules: an import outside the allowlist,
    AppKit outside its one file, or a `Package.swift` target that gained a dependency or lost its
    strict-concurrency flag. A missing target or an extractor that finds no import fails too, so the
    fence cannot go vacuously green. Pure apart from reading the files."""
    out: list[str] = []
    core = repo / "daemon" / "Sources" / "MeetingPipeCore"
    found = 0
    for path in sorted(core.rglob("*.swift")):
        rel = path.relative_to(repo).as_posix()
        code = "\n".join(_swift_code_lines(path.read_text(encoding="utf-8")))
        for match in SWIFT_IMPORT.finditer(code):
            found += 1
            module = match.group(1)
            where = f"{rel}:{code.count(chr(10), 0, match.start()) + 1}"
            if module == "AppKit" and rel != CORE_APPKIT_FILE:
                out.append(f"`import AppKit` at {where}. Core has exactly one, in {CORE_APPKIT_FILE}, for an "
                           "API with no Foundation equivalent; reach the rest through a protocol the app implements.")
            elif module not in CORE_IMPORT_ALLOWLIST:
                out.append(f"`import {module}` at {where} is outside the Core island's allowlist "
                           f"({', '.join(sorted(CORE_IMPORT_ALLOWLIST))}). No UI in Core; a new module is an "
                           "island-rule change, so ask first and extend CORE_IMPORT_ALLOWLIST with it.")
    if found == 0:
        out.append("found no `import` under daemon/Sources/MeetingPipeCore; the island extractor is stale")

    package = repo / "daemon" / "Package.swift"
    src = "\n".join(_swift_code_lines(package.read_text(encoding="utf-8"))) if package.exists() else ""
    target = CORE_TARGET.search(src)
    if target is None:
        out.append("no `.target(name: \"MeetingPipeCore\"` in daemon/Package.swift; the island extractor is stale")
        return out
    span = _call_span(src, target.start(1))
    deps = re.search(r"\bdependencies:\s*\[", span)
    deps_text = re.sub(r"\s+", "", _call_span(span, deps.end() - 1, "[]")[1:-1]) if deps else ""
    if deps_text.rstrip(",") != CORE_ONLY_DEPENDENCY:
        out.append(f"the MeetingPipeCore target's dependencies are `{deps_text or '(none)'}`; TOMLKit is its only "
                   "dependency, and adding one means every test that links Core links it too. Ask first.")
    if not CORE_STRICT_CONCURRENCY.search(span):
        out.append("the MeetingPipeCore target no longer passes `-strict-concurrency=targeted` (or `complete`). "
                   "A Sendable warning there is a real cross-thread finding; keep the flag on.")
    return out


def check_sources(
    repo: Path | None = None,
    allowlist: dict[tuple[str, str], tuple[int, str]] | None = None,
) -> bool:
    fence = Fence("daemon source rules")
    repo = repo if repo is not None else REPO
    allowlist = NSERROR_ALLOWLIST if allowlist is None else allowlist
    for msg in island_failures(repo):
        fence.fail(msg)
    hits = nserror_hits(repo)

    for key, (count, reason) in sorted(allowlist.items()):
        if not reason.strip():
            fence.fail(f"NSERROR_ALLOWLIST entry {key[0]} / {key[1]} has no reason")
        found = len(hits.get(key, []))
        if found == 0:
            fence.fail(f"NSERROR_ALLOWLIST entry {key[0]} / {key[1]} is stale: no such construction is left. "
                       "Delete the entry.")
        elif found != count:
            fence.fail(
                f"{key[0]}: {found} `NSError(domain: {key[1]}` construction(s) where NSERROR_ALLOWLIST expects "
                f"{count}. Name the new failure in a LocalizedError, or update the entry if one was removed."
            )
    for (rel, domain), lines in sorted(hits.items()):
        if (rel, domain) in allowlist:
            continue
        where = ", ".join(f"{rel}:{n}" for n in lines)
        fence.fail(
            f"`NSError(domain: {domain}` ({where}). CONVENTIONS.md: name the failure in the subsystem's "
            "nested `enum X: Error, LocalizedError` instead (MeetingLibraryService.LibraryError is the shape)."
        )
    return fence.report()


# --------------------------------------------------------------------------
# Fence 7 (HYG21): the owner's people and meetings stay out of tests and scripts
# --------------------------------------------------------------------------

# Where a roster name or the owner's label may not appear (as a whole word). One constant, so
# widening the fence to `daemon/` or the docs is a one-line change.
# T20: the detection corpus too, since a trace's `description` is hand-written prose bound for
# the public repo; `redact_detection_trace.py --check` runs the same roster scan per trace.
PERSONAL_NAME_PATHS = ("pipeline/", "scripts/", "daemon/Tests/MeetingPipeCoreTests/Fixtures/detection-corpus/")
# Where a library stem may not appear. Narrower: docs cite real stems as measurements on purpose.
PERSONAL_STEM_PATHS = ("pipeline/tests/", "scripts/")
STEM = re.compile(r"\b20\d{6}-\d{6}\b")
DEFAULT_ROSTER = Path("~/.config/meeting-pipe/roster.json").expanduser()
DEFAULT_CONFIG = Path("~/.config/meeting-pipe/config.toml").expanduser()
DEFAULT_LIBRARY = Path("~/Documents/Meetings/raw").expanduser()


def personal_sources(
    roster: Path, config: Path, library: Path | None
) -> tuple[list[tuple[str, str]], set[str], bool]:
    """(labelled name tokens, library stems, any source present). Read from the owner's own
    files, never from the repo: a committed denylist of names would commit the names."""
    import json

    found = False
    raw: list[tuple[str, str]] = []
    if roster.is_file():
        found = True
        try:
            people = json.loads(roster.read_text(encoding="utf-8")).get("people") or []
        except (OSError, ValueError, AttributeError):
            people = []
        for k, person in enumerate(people, 1):
            if isinstance(person, dict) and isinstance(person.get("name"), str):
                raw.append((f"roster name #{k}", person["name"]))
    output_dir: Path | None = None
    if config.is_file():
        found = True
        try:
            cfg = tomllib.loads(config.read_text(encoding="utf-8"))
        except (OSError, tomllib.TOMLDecodeError):
            cfg = {}
        label = (cfg.get("summarization") or {}).get("user_label")
        if isinstance(label, str):
            raw.append(("user label", label))
        configured = (cfg.get("recording") or {}).get("output_dir")
        if isinstance(configured, str) and configured:
            output_dir = Path(configured).expanduser()
    lib = library or output_dir or DEFAULT_LIBRARY
    stems: set[str] = set()
    if lib.is_dir():
        found = True
        stems = {m.group(0) for p in lib.iterdir() if (m := STEM.match(p.name))}
    # Whole words of three letters or more: a first name alone is how the leak looked.
    names = [(tag, tok) for tag, full in raw for tok in re.findall(r"[^\W\d_]{3,}", full)]
    return names, stems, found


def personal_hits(
    root: Path, files: list[str], names: list[tuple[str, str]], stems: set[str]
) -> list[str]:
    """`file:line: <which source>` for every hit. Never the matched text, so the fence's own
    output carries no name. Pure over the given file list."""
    patterns = [(tag, re.compile(r"(?<![^\W_])" + re.escape(tok) + r"(?![^\W_])", re.IGNORECASE))
                for tag, tok in names]
    out: list[str] = []
    for rel in files:
        in_names = rel.startswith(PERSONAL_NAME_PATHS)
        in_stems = rel.startswith(PERSONAL_STEM_PATHS)
        if not (in_names or in_stems):
            continue
        try:
            text = (root / rel).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for n, line in enumerate(text.splitlines(), 1):
            if in_names:
                for tag, pat in patterns:
                    if pat.search(line):
                        out.append(f"{rel}:{n}: {tag}")
            if in_stems and stems:
                if any(m.group(0) in stems for m in STEM.finditer(line)):
                    out.append(f"{rel}:{n}: library stem")
    return out


def _tracked_files(root: Path) -> list[str]:
    import subprocess

    try:
        res = subprocess.run(["git", "-C", str(root), "ls-files"], capture_output=True, text=True, check=True)
        return res.stdout.splitlines()
    except (OSError, subprocess.CalledProcessError):
        return [str(p.relative_to(root)) for p in root.rglob("*") if p.is_file()]


def check_personal(
    root: Path = REPO,
    roster: Path = DEFAULT_ROSTER,
    config: Path = DEFAULT_CONFIG,
    library: Path | None = None,
) -> bool:
    """An owner-machine check by design: CI has no roster, config or library and skips."""
    fence = Fence("personal names and stems")
    names, stems, found = personal_sources(roster, config, library)
    if not found:
        print("  SKIP: personal names and stems (no roster, config or library on this machine)")
        return True
    for hit in personal_hits(root, _tracked_files(root), names, stems):
        fence.fail(f"{hit}: use a synthetic name or stem in fixtures and examples (HYG21)")
    return fence.report()


# --------------------------------------------------------------------------
# Fence 8 (OBS6): every MP_* variable the daemon exports has a pipeline reader
# --------------------------------------------------------------------------

# How the daemon hands a variable to `mp`: `setenv("MP_X"`, `env["MP_X"] =`, a `["MP_X": ...]`
# extra-env literal, or a `static let ...Env/Key = "MP_X"` constant. `MP_VERBOSE` was exported for
# months with no reader at all, a third store neither the config fence nor the pipeline checked.
ENV_EXPORT = re.compile(
    r'setenv\(\s*"(MP_[A-Z0-9_]+)"'
    r'|env\[\s*"(MP_[A-Z0-9_]+)"\s*\]\s*='
    r'|\[\s*"(MP_[A-Z0-9_]+)"\s*:'
    r'|static let \w*(?:[Ee]nv|Key)\w*\s*=\s*"(MP_[A-Z0-9_]+)"'
)


def env_exports(swift: dict[str, str]) -> dict[str, str]:
    """{name: first `path:line`} of every MP_* the daemon sources export. Pure."""
    out: dict[str, str] = {}
    for path, src in swift.items():
        for m in ENV_EXPORT.finditer(src):
            name = next(g for g in m.groups() if g)
            out.setdefault(name, f"{path}:{src.count(chr(10), 0, m.start()) + 1}")
    return out


def unread_env_exports(swift: dict[str, str], python: dict[str, str]) -> list[str]:
    exports = env_exports(swift)
    pipeline = "\n".join(python.values())
    return [f"{where}: `{name}` is exported to `mp` but nothing under pipeline/src reads it"
            for name, where in sorted(exports.items()) if name not in pipeline]


def check_env() -> bool:
    fence = Fence("exported MP_ variables")
    swift = {str(p.relative_to(REPO)): p.read_text(encoding="utf-8") for p in _swift_sources()}
    python = {
        str(p.relative_to(REPO)): p.read_text(encoding="utf-8")
        for p in sorted((REPO / "pipeline" / "src" / "mp").rglob("*.py"))
    }
    if len(env_exports(swift)) < 3:
        fence.fail("found fewer than 3 MP_ exports in daemon/Sources; the extractor is stale")
    for msg in unread_env_exports(swift, python):
        fence.fail(msg + ". Read it, or stop exporting it (OBS6).")
    return fence.report()


def main(argv: list[str]) -> int:
    which = argv[0] if argv and not argv[0].startswith("--") else "both"
    flags = dict(zip(argv[1::2], argv[2::2], strict=False)) if argv and not argv[0].startswith("--") else dict(zip(argv[::2], argv[1::2], strict=False))
    print(f"CI5 truth fences ({which})")
    ok = True
    if which in ("both", "config"):
        ok &= check_config()
    if which in ("both", "events"):
        ok &= check_events()
    if which in ("both", "claude"):
        ok &= check_claude()
    if which in ("both", "links"):
        ok &= check_links()
    if which in ("both", "backlog"):
        ok &= check_backlog()
    if which in ("both", "blockers"):
        ok &= check_blockers()
    if which in ("both", "env"):
        ok &= check_env()
    if which in ("both", "sources"):
        ok &= check_sources()
    if which in ("both", "personal"):
        ok &= check_personal(
            roster=Path(flags.get("--roster", DEFAULT_ROSTER)).expanduser(),
            config=Path(flags.get("--config", DEFAULT_CONFIG)).expanduser(),
            library=Path(flags["--library"]).expanduser() if "--library" in flags else None,
        )
    if which not in ("both", "config", "events", "claude", "links", "backlog", "blockers", "env", "sources",
                     "personal"):
        print("usage: truth_fences.py [both|config|events|claude|links|backlog|blockers|env|sources|personal]"
              " [--roster F] [--config F] [--library D]", file=sys.stderr)
        return 2
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
