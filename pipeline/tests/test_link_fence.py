"""HYG8 item 4: the CI5 `links` fence, pinned against the bugs that filed it.

Two failure classes, both archive hygiene, both invisible in a diff:

  * a relative link that stopped resolving when its spec was archived one
    directory up (HYG6 swept 88, HYG8 another 24), and
  * a bold paragraph glued to the block above it, in two shapes: a `**[DONE]`
    entry a both-sides-add merge left touching the previous entry (UX72,
    FEAT15), and any bold line directly under a list item, which markdown
    swallows into that item. The second was added after the first version of
    this fence passed over a live instance of it in `design/ui_kits/`.

The two **skips** matter as much as the two checks, and they are what makes
this fence shippable at all: `meetingpipe://` is real documented content, and a
spec quoting a broken link is how this repo records that a link is broken. A
fence firing on either would make correct prose unwriteable, so both are pinned
here rather than left to a suppression list, which is the thing that rots next.

`scripts/truth_fences.py` is a script rather than a package module, so it is
loaded by path, following `test_feat17_probe.py`'s precedent for the four
`docs/spikes/` probes.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

_FENCES = Path(__file__).resolve().parents[2] / "scripts" / "truth_fences.py"


def _load():
    spec = importlib.util.spec_from_file_location("truth_fences", _FENCES)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


tf = _load()


# --- the two checks -----------------------------------------------------------

def test_a_broken_relative_link_is_a_finding(tmp_path):
    (tmp_path / "here.md").write_text("[a spec](../tasks/NOPE9.md)\n", encoding="utf-8")
    links = tf.markdown_links((tmp_path / "here.md").read_text(encoding="utf-8"))
    assert links == [(1, "../tasks/NOPE9.md")]
    assert not tf.resolve_link(tmp_path, "../tasks/NOPE9.md").exists()


def test_a_link_that_resolves_is_not_a_finding(tmp_path):
    (tmp_path / "target.md").write_text("hi\n", encoding="utf-8")
    assert tf.resolve_link(tmp_path, "./target.md").exists()


def test_a_done_entry_glued_to_the_paragraph_above_is_a_finding():
    """The UX72 shape. A `**[DONE]` line is a bold paragraph, not a heading, so
    with no blank line above it markdown treats it as a lazy continuation and
    renders two entries as one."""
    text = "Closing line of the previous entry.\n**[DONE] RUNON1: glued.**\n"
    assert [n for n, _ in tf.run_on_lines(text)] == [2]


def test_a_done_entry_with_its_blank_line_is_not_a_finding():
    text = "Closing line of the previous entry.\n\n**[DONE] FINE1: separated.**\n"
    assert tf.run_on_lines(text) == []


def test_a_done_entry_opening_the_file_is_not_a_finding():
    """Nothing above it to run on to, so the `n > 1` guard has to hold."""
    assert tf.run_on_lines("**[DONE] FIRST1: opens the file.**\n") == []


def test_a_bold_paragraph_glued_to_a_list_item_is_a_finding():
    """The second shape, found in `design/ui_kits/macos_app/README.md` on
    2026-08-19: markdown swallows the paragraph into the bullet above it, so
    DSN30's own answer was rendering inside an unrelated bullet."""
    text = "- a bullet about something else\n**The answer to a different question.** Body.\n"
    lines = tf.run_on_lines(text)
    assert [n for n, _ in lines] == [2]
    assert "list item" in lines[0][1]


def test_a_bold_paragraph_after_a_blank_line_is_not_a_finding():
    text = "- a bullet about something else\n\n**The answer.** Body.\n"
    assert tf.run_on_lines(text) == []


def test_a_bold_lead_in_after_ordinary_prose_is_not_a_finding():
    """The rule is deliberately narrower than 'bold after any non-blank line'.
    A bold lead-in following a sentence is ordinary style in this repo and must
    never fire, or the fence becomes one nobody can keep green."""
    assert tf.run_on_lines("A sentence of prose.\n**A bold lead-in.** More prose.\n") == []


# --- the two non-negotiable skips ---------------------------------------------

@pytest.mark.parametrize(
    "target",
    [
        "meetingpipe://open?stem=20260814-163455",  # documented in q6-final.md and CONVENTIONS.md
        "https://example.com/x",
        "http://example.com/x",
        "mailto:someone@example.com",
        "#an-in-page-anchor",
    ],
)
def test_a_non_file_target_is_never_resolved_as_a_path(target):
    assert tf.resolve_link(Path("/nonexistent"), target) is None


def test_a_broken_link_quoted_in_an_inline_code_span_is_invisible():
    """HYG7 quotes END9's broken `PromptEndPolicy.swift#L7` link precisely to
    record that it is broken. A fence that fails on that makes the finding
    unwriteable."""
    text = "See `[x](../../daemon/Sources/MeetingPipe/PromptEndPolicy.swift#L7)` which is dead.\n"
    assert tf.markdown_links(text) == []


def test_a_broken_link_quoted_in_a_fenced_block_is_invisible():
    text = "before\n\n```\n[dead](../../nowhere/at/all.md)\n```\n\nafter\n"
    assert tf.markdown_links(text) == []


def test_stripping_code_preserves_line_numbers():
    """A finding has to be able to name its line, so the stripper blanks rather
    than removes."""
    text = "a\n```\nb\n```\nc\n"
    assert len(tf.strip_code(text).splitlines()) == len(text.splitlines())


def test_an_anchor_is_stripped_before_the_path_is_resolved(tmp_path):
    (tmp_path / "doc.md").write_text("x\n", encoding="utf-8")
    assert tf.resolve_link(tmp_path, "./doc.md#some-section").exists()


# --- the walker ---------------------------------------------------------------

def test_the_walker_sees_the_real_doc_tree():
    """A fence whose walker stops finding files passes silently, which is the
    one failure a fence must never have. `check_links` has its own floor; this
    pins that the floor is not the whole population."""
    found = tf.doc_files()
    assert len(found) > 100
    names = {p.name for p in found}
    assert {"README.md", "ARCHITECTURE.md", "CONVENTIONS.md"} <= names


def test_the_walker_skips_worktrees_and_build_output():
    """Session worktrees under `.claude/` hold whole copies of the tree, which
    would double every finding under a path nobody edits.

    Relative to the repo root, as the walker itself checks: the absolute path of a
    checkout that is itself a worktree runs through `.claude/worktrees/`, so testing
    `p.parts` failed in every worktree session and passed only on CI (CI8)."""
    assert all(
        not ({".claude", ".build", "node_modules"} & set(p.relative_to(tf.REPO).parts))
        for p in tf.doc_files()
    )


def test_the_real_tree_is_currently_clean():
    """The fence landed green on 2026-08-19, after HYG6 and HYG8 repaired 112
    links between them. This is the regression guard: the next archive move that
    drops a `../` level fails here."""
    assert tf.check_links() is True
