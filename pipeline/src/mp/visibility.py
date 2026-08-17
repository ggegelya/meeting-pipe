"""Which meetings may leave this machine (AUTO3, leg 0).

`config.zero_egress` is the single owner of "may this *run* reach a cloud
service". This module is its per-meeting counterpart: the single owner of "may
this *meeting* be handed to something outside meeting-pipe", and every
library-wide surface that can egress asks it rather than deciding for itself.

**Why a second owner was needed at all.** `zero_egress` is
``regulated_mode or workflow_nda_mode``, and `workflow_nda_mode` is only ever
set by `workflow.apply_overrides` from one meeting's `<stem>.meta.json`. A
library-wide command has no meeting to anchor on, so it calls `entry.prepare()`
with no anchor and that flag can never become true: only the global
`regulated_mode` can clamp it. `mp ask` and `mp digest` both shipped that way
(each with an inline "Library-wide, so no meeting anchor" comment), so on a Mac
with `regulated_mode = false` and a cloud backend, an NDA meeting's text was
retrievable into a prompt that egresses. `embed_index.chunk_library` applied no
policy filter at all, so the withheld text was in the index those two search.
That is what this module closes, and the MCP server (AUTO3 legs 1-3) is only
the surface that made it urgent.

**Fail closed, by the owner's decision on 2026-07-27** (fail-open-on-unknowns,
expose-everything and per-workflow opt-in were named and declined). Three
reasons withhold a meeting:

  - `nda`: the sidecar flags `workflow_nda_mode`.
  - `regulated`: the sidecar flags `regulated_mode`. TECH-DSN6 persists that
    into the sidecar at record time and `workflow.apply_overrides` folds it in
    fail-closed, so a meeting recorded under regulated mode stays clamped even
    after the global flag is turned off. Withholding it here is the same rule
    applied to the same evidence.
  - `no_sidecar`: there is no `<stem>.meta.json`, or it does not parse. These
    predate the workflow feature, so their policy stance is genuinely unknown,
    and unknown is not permission. A malformed sidecar reads the same as a
    missing one on purpose (`workflow.read_meta` already returns `{}` for
    both): a policy gate must not be openable by corrupting a file.

Everything else is visible. On the owner's library at filing time that was 175
of 217 (3 NDA, 39 with no sidecar).

Stdlib only and pure, so the gate is unit-testable without an index, a model, or
a config, and so `embed_index` can build on it rather than the other way round.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .workflow import read_meta

#: Why a stem is withheld. A visible stem has no reason. These strings reach the
#: `mp mcp-serve --status --json` payload the Preferences readout renders, so
#: they are part of the Swift-facing contract, not debug text.
WITHHELD_NDA = "nda"
WITHHELD_REGULATED = "regulated"
WITHHELD_NO_SIDECAR = "no_sidecar"


def library_stems(root: Path) -> list[str]:
    """Every meeting stem under `root` that has summary or transcript text.

    The one definition of "the library" for both the embedding index and this
    gate, so the corpus a search ranks over and the corpus a policy decides
    about cannot drift apart. `<stem>.md` is the transcript (one dot);
    `<stem>.summary.md` has more, which is what the dot count screens out.
    """
    root = Path(root).expanduser()
    if not root.is_dir():
        return []
    stems: set[str] = set()
    for p in root.glob("*.md"):
        if p.name.count(".") == 1:
            stems.add(p.name.split(".", 1)[0])
    for p in root.glob("*.summary.json"):
        stems.add(p.name.split(".", 1)[0])
    return sorted(stems)


def withheld_reason(root: Path, stem: str) -> str | None:
    """Why `stem` may not leave this machine, or None when it may.

    The single named function AUTO3's acceptance asks for: every caller that can
    hand meeting text to something outside this process routes through here, so
    a later tool cannot forget the rule by holding its own copy of it.
    """
    root = Path(root).expanduser()
    meta = read_meta(root / f"{stem}.meta.json")
    if not meta:
        return WITHHELD_NO_SIDECAR
    if meta.get("workflow_nda_mode"):
        return WITHHELD_NDA
    if meta.get("regulated_mode"):
        return WITHHELD_REGULATED
    return None


def is_visible(root: Path, stem: str) -> bool:
    """True when `stem` may leave this machine.

    Deliberately does not check that the meeting exists: a stem with no files
    has no sidecar either, so it is withheld. That is what makes "withheld" and
    "never existed" the same answer to a caller, which AUTO3 leg 2 requires so
    the server cannot reveal that a meeting it will not show exists.
    """
    return withheld_reason(root, stem) is None


@dataclass(frozen=True)
class LibraryVisibility:
    """The whole library's verdict, computed once so a caller does not re-stat
    the same sidecars per tool call.

    `withheld` maps stem -> reason rather than being a bare set, because the
    Preferences readout has to say *why* meetings are unreachable; a count with
    no reason is the kind of number a user quietly stops believing.
    """

    visible: tuple[str, ...]
    withheld: dict[str, str]

    @property
    def visible_count(self) -> int:
        return len(self.visible)

    @property
    def withheld_count(self) -> int:
        return len(self.withheld)

    @property
    def visible_set(self) -> set[str]:
        return set(self.visible)

    def reason_counts(self) -> dict[str, int]:
        """Withheld stems per reason, for the Preferences caption."""
        counts: dict[str, int] = {}
        for reason in self.withheld.values():
            counts[reason] = counts.get(reason, 0) + 1
        return dict(sorted(counts.items()))

    def to_json(self) -> dict:
        return {
            "visible": self.visible_count,
            "withheld": self.withheld_count,
            "withheld_by_reason": self.reason_counts(),
        }


def library_visibility(root: Path) -> LibraryVisibility:
    """Decide every meeting in `root` at once."""
    root = Path(root).expanduser()
    visible: list[str] = []
    withheld: dict[str, str] = {}
    for stem in library_stems(root):
        reason = withheld_reason(root, stem)
        if reason is None:
            visible.append(stem)
        else:
            withheld[stem] = reason
    return LibraryVisibility(visible=tuple(visible), withheld=withheld)


def visible_stems(root: Path) -> set[str]:
    """The allowlist every egressing surface passes down. A set rather than the
    whole `LibraryVisibility`, so callers that only need "may I include this
    row" do not carry reasons they will never render."""
    return library_visibility(root).visible_set
