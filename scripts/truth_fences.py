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
  2. An **undocumented event category**: a `Log.event` / `events.emit` category
     absent from the CONVENTIONS.md table, so a session reading that table to
     orient gets an incomplete map of the event stream.

Both are drift between prose and code, which is exactly what a human reviewer
stops noticing. This script is the mechanical reader.

    python3 scripts/truth_fences.py            # both fences
    python3 scripts/truth_fences.py config     # config keys only
    python3 scripts/truth_fences.py events     # event categories only

Stdlib only (tomllib, ast, re), so CI can run it without installing anything.

**The allowlists below are a ratchet, not an exemption.** Each entry names the
backlog task that will clear it. Anything NOT listed fails, so the fence is
live for new drift from the day it lands, while the known-drift backlog stays
honest and visible instead of being silently tolerated. Clearing the owning
task means deleting lines from these lists, and a stale entry also fails, so
the lists cannot outlive the drift they describe. HYG2's three dead-knob
entries were removed this way when the knobs were wired or deleted.
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
CONFIG_ALLOWLIST: dict[str, str] = {
    # DOC9: real keys the pipeline parses that `config.example.toml` never
    # shows, so the file is not the complete reference it reads as. The five
    # sink keys below are additionally in the README but not the example file,
    # which the completeness check catches separately.
    "output.sinks": "DOC9: config.example.toml has no [output] section",
    "obsidian.vault_path": "DOC9: config.example.toml has no [obsidian] section",
    "obsidian.folder": "DOC9: config.example.toml has no [obsidian] section",
    "obsidian.template_path": "DOC9: config.example.toml has no [obsidian] section",
    "obsidian.attach_audio": "DOC9: config.example.toml has no [obsidian] section",
    "obsidian.attachments_subfolder": "DOC9: config.example.toml has no [obsidian] section",
    "obsidian.daily_note_backlink": "DOC9: config.example.toml has no [obsidian] section",
    "filesystem.output_dir": "DOC9: config.example.toml has no [filesystem] section",
    "lan.mount_path": "DOC9: config.example.toml has no [lan] section",
    "lan.host": "DOC9: config.example.toml has no [lan] section",
    "detection.default_prompt_action": "DOC9: read by both trees, absent from config.example.toml",
}

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


def main(argv: list[str]) -> int:
    which = argv[0] if argv else "both"
    print(f"CI5 truth fences ({which})")
    ok = True
    if which in ("both", "config"):
        ok &= check_config()
    if which in ("both", "events"):
        ok &= check_events()
    if which not in ("both", "config", "events"):
        print("usage: truth_fences.py [both|config|events]", file=sys.stderr)
        return 2
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
