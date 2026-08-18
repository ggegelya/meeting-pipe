#!/usr/bin/env python3
"""CI5: fences that diff what the docs SAY against what the code DOES.

Two failure classes recur in this repo and neither is catchable by a type
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

The first two are drift between prose and code, which is exactly what a human
reviewer stops noticing. The third is drift between a file's job and its size.
This script is the mechanical reader.

    python3 scripts/truth_fences.py            # all three fences
    python3 scripts/truth_fences.py config     # config keys only
    python3 scripts/truth_fences.py events     # event categories only
    python3 scripts/truth_fences.py claude     # CLAUDE.md size budget only

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
import re
import sys
import tomllib
from pathlib import Path

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

# Parsed at runtime but deliberately never sourced from TOML, so neither the
# documented-vs-parsed diff nor the completeness check applies.
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

    for rel in ("daemon/Sources/MeetingPipe/Config.swift",
                "daemon/Sources/MeetingPipe/ConfigStore.swift"):
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
        for section, key in re.findall(r'ensureTable\("([a-z_]+)"\)\["([a-z_]+)"\]', store)
    }
    if not written:
        raise SystemExit("ConfigStore.swift: found no ensureTable writes")
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
    for name, body in re.findall(r"\bfunc\s+(\w+)\s*\([^)]*\)[^{]*\{(.*?)\n        \}", src, re.S):
        for alias in re.findall(r"\b(\w+)\?\[\s*key\s*\]", body):
            if alias in aliases:
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

    for key in unconsumed_keys(read):
        drift.add(key)
        if key in known:
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

    return fence.report()


# --------------------------------------------------------------------------
# Fence 2: event categories and action names
# --------------------------------------------------------------------------

SWIFT_EMIT = re.compile(r'(?:Log\.event|\.emit)\(\s*category:\s*"([a-z_]+)"')
# Scoped to the emit call, NOT a bare `action:` label: `LibraryError.noTranscript`
# also takes an `action:` and its value is a human sentence ("re-run"), which a
# loose regex reports as a convention violation forever.
SWIFT_EMIT_ACTION = re.compile(
    r'(?:Log\.event|\.emit)\(\s*category:\s*"[a-z_]+",\s*action:\s*([^\n]*?),\s*attributes:'
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
            if not (line.startswith("- ") or line.startswith("| ")):
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


def main(argv: list[str]) -> int:
    which = argv[0] if argv else "both"
    print(f"CI5 truth fences ({which})")
    ok = True
    if which in ("both", "config"):
        ok &= check_config()
    if which in ("both", "events"):
        ok &= check_events()
    if which in ("both", "claude"):
        ok &= check_claude()
    if which not in ("both", "config", "events", "claude"):
        print("usage: truth_fences.py [both|config|events|claude]", file=sys.stderr)
        return 2
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
