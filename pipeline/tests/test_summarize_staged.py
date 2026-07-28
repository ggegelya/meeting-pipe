"""Unit tests for LOCAL14's staged local pipeline (extract, compose, verify).

Every stage is exercised against a **scripted fake**: either a `_Script` object
standing in for the chat-completion call, or the same in-process fake
`mlx_lm.server` `test_summarize_local.py` uses. No model is ever loaded and no
real socket leaves the machine, which is the only way these can pin the pipeline's
*shape* rather than one model's mood on one day.

The script deliberately answers each stage with output a small unconstrained model
plausibly produces: a thinking-mode prefix, a Markdown fence, a dropped comma, a
quote that was never in the transcript. Those are not adversarial inventions; each
one is a failure mode LOCAL13 or the 2026-07-27 lost-meeting incident measured on
this exact seam.
"""
from __future__ import annotations

import json
import threading
from http.server import ThreadingHTTPServer

import pytest

from mp import summarize_staged as staged
from mp.evidence import segments_from_timestamped_markdown
from mp.schemas import Evidence
from mp.summarize_local import LocalSummaryClient

from .test_summarize_local import _FakeHandler  # the same fake mlx_lm.server


# ----- Fixtures -----

_TURNS = [
    (0, "Alice", "Morning everyone, quick standup before the release window opens."),
    (30, "Alice", "I will ship the hotfix to staging before Friday."),
    (60, "Bob", "Can you also update the runbook for DMS-6796 while you are in there?"),
    (90, "Alice", "Yes, I will take DMS-6796 as well and post the diff for review."),
    (120, "Carol", "We should look at moving the nightly job, but let us think about it next week."),
    (150, "Bob", "Who owns the release notes for this one, because that is still open?"),
    (180, "Carol", "I can draft the release notes if nobody else has started on them."),
    (210, "Alice", "Good, so we agreed Carol drafts the notes and I ship the hotfix."),
    (240, "Bob", "One more thing, the staging database restore is still flaky for me."),
    (270, "Carol", "Let us park the restore until the release is safely out of the way."),
    (300, "Alice", "Agreed, parking it. Anything else before we close this one out?"),
    (330, "Bob", "Nothing from me, the rest of my week is review work and nothing new."),
    (360, "Carol", "Same here, I am only on the notes and the follow-up ticket triage."),
    (390, "Alice", "Then that is us. I will send the summary out after this call ends."),
]


def _transcript(repeat: int = 1) -> str:
    """The timestamped render `LocalSummaryClient` actually sends (FEAT10)."""
    lines = ["# Transcript - 20260723-103118", "", "_Language detected: en_", ""]
    offset = 0
    for _ in range(repeat):
        for t, speaker, text in _TURNS:
            m, s = divmod(t + offset, 60)
            lines.append(f"[{m}:{s:02d}] **{speaker}**: {text}")
            lines.append("")
        offset += 420
    return "\n".join(lines)


TRANSCRIPT = _transcript()


def _facts_reply() -> str:
    """A Stage 1 reply whose quotes are all really in the transcript, wrapped in
    the thinking-mode prose a hybrid Qwen3 build emits by default (LOCAL13 leg 3)."""
    return "Let me read the slice carefully.\n\n" + json.dumps({"facts": [
        {"kind": "commitment", "text": "Alice ships the hotfix", "who": "Alice",
         "quote": "I will ship the hotfix to staging before Friday", "t": "0:30"},
        {"kind": "request", "text": "Bob asks for a runbook update", "who": "Bob",
         "quote": "Can you also update the runbook for DMS-6796", "t": "1:00"},
        {"kind": "artifact", "text": "DMS-6796 is the ticket", "who": None,
         "quote": "I will take DMS-6796 as well", "t": "1:30"},
        {"kind": "question", "text": "Release-note ownership is open", "who": "Bob",
         "quote": "Who owns the release notes for this one", "t": "2:30"},
        {"kind": "commitment", "text": "Carol drafts the release notes", "who": "Carol",
         "quote": "I can draft the release notes", "t": "3:00"},
        {"kind": "identity", "text": "Carol is present", "who": "Carol",
         "quote": "Same here, I am only on the notes", "t": "6:00"},
    ]})


class _Script:
    """A scripted stand-in for `LocalSummaryClient._chat_completion`.

    Routes on the system turn, records every call, and raises whatever a test
    parks in `fail` for a stage. Recording the messages is what lets the Stage 2
    isolation probe assert on what the composer was actually shown.
    """

    def __init__(self, **replies: str) -> None:
        self.replies = replies
        self.calls: list[tuple[str, list[dict[str, str]]]] = []
        self.fail: dict[str, Exception] = {}

    def stage_of(self, system: str) -> str:
        if system.startswith("You extract atomic facts"):
            return "extract"
        if system.startswith("You are checking a list of candidate decisions"):
            return "critic"
        for section in ("summary", "decisions", "questions", "actions", "title"):
            if staged._SECTION_INSTRUCTIONS[section] in system:
                return section
        raise AssertionError(f"unrecognised stage prompt: {system[:80]!r}")

    def __call__(self, *, messages, max_tokens, response_format=None) -> str:
        stage = self.stage_of(messages[0]["content"])
        self.calls.append((stage, messages))
        if stage in self.fail:
            raise self.fail[stage]
        return self.replies.get(stage, '{"items": []}')

    def messages_for(self, stage: str) -> list[dict[str, str]]:
        for name, messages in self.calls:
            if name == stage:
                return messages
        raise AssertionError(f"stage {stage} was never called")


def _points(*items: tuple[str, list[int]]) -> str:
    return json.dumps({"items": [{"text": t, "facts": f} for t, f in items]})


def _happy_script(**overrides: str) -> _Script:
    replies = {
        "extract": _facts_reply(),
        "summary": _points(
            ("Alice takes the hotfix to staging before Friday.", [0]),
            ("Carol picks up the release notes.", [4]),
        ),
        "decisions": _points(
            ("Carol drafts the release notes.", [4]),
            ("Alice ships the hotfix before Friday.", [0]),
        ),
        "questions": _points(("Who owns the release notes?", [3])),
        "actions": json.dumps({"items": [
            {"task": "Ship the hotfix to staging", "owner": "Alice", "due": None, "facts": [0]},
            {"task": "Update the DMS-6796 runbook", "owner": "Bob", "due": None, "facts": [1]},
        ]}),
        "title": '```json\n{"title": "Release window standup"}\n```',
        "critic": '{"keep": [0, 1]}',
    }
    replies.update(overrides)
    return _Script(**replies)


def _run(script: _Script, transcript: str = TRANSCRIPT):
    return staged.run_staged(
        chat=script, transcript=transcript, target="en", max_tokens=4000
    )


# ----- The toggle -----

def test_staged_is_off_by_default() -> None:
    """LOCAL14 ships behind a toggle and does NOT flip the default; adoption waits
    on the pre-registered dogfood verdict."""
    assert staged.staged_enabled({}) is False
    assert staged.staged_enabled({"MP_STAGED_LOCAL": ""}) is False
    assert staged.staged_enabled({"MP_STAGED_LOCAL": "0"}) is False


@pytest.mark.parametrize("value", ["1", "true", "TRUE", "yes", "on"])
def test_staged_toggle_accepts_the_usual_truthy_spellings(value: str) -> None:
    assert staged.staged_enabled({"MP_STAGED_LOCAL": value}) is True


# ----- Window sizing -----

def test_window_chars_is_script_aware_and_beats_the_flat_budget() -> None:
    """LOCAL13 measured Cyrillic at roughly 2x the tokens per char of English, so
    a flat char budget is either wasteful on English or unsafe on Ukrainian. Both
    windows here are far larger than the single-pass path's worst-case 1,500."""
    english = staged.window_chars("the quick brown fox jumps over the lazy dog " * 40)
    ukrainian = staged.window_chars("швидка бура лисиця стрибає через ледачого пса " * 40)
    assert english > ukrainian
    assert ukrainian > 1_500
    # The two budgets should land on comparable token costs, not comparable chars.
    assert 1.7 < english / ukrainian < 2.3


def test_tokens_per_char_brackets_the_measured_range() -> None:
    assert staged.tokens_per_char("hello there everyone") == pytest.approx(0.25)
    assert staged.tokens_per_char("привіт усім разом") == pytest.approx(0.49)
    assert 0.25 < staged.tokens_per_char("hello привіт") < 0.49


# ----- Stage 1: EXTRACT -----

def test_extraction_rows_carry_a_quote_and_a_timestamp() -> None:
    rows = staged.parse_facts(_facts_reply())
    assert len(rows) == 6
    assert all(row.quote for row in rows)
    assert all(row.kind in staged.FACT_KINDS for row in rows)
    # `[mm:ss]` is decoded to seconds, so Stage 3 can resolve it against segments.
    assert [row.t for row in rows[:3]] == [30.0, 60.0, 90.0]
    assert rows[0].who == "Alice"
    assert rows[2].who is None


def test_extraction_drops_a_row_it_cannot_quote_without_losing_the_window() -> None:
    """A row with no quote can never be verified, so it would only ever add
    unanchored prose to the composer's input. One bad row costs its own row."""
    rows = staged.parse_facts(json.dumps({"facts": [
        {"kind": "commitment", "text": "no quote here", "who": "Alice", "quote": "", "t": 10},
        {"kind": "nonsense", "text": "bad kind", "who": None, "quote": "real words", "t": 10},
        {"kind": "commitment", "text": "keeps", "who": "Bob", "quote": "real words", "t": 10},
        "not even an object",
    ]}))
    assert [row.text for row in rows] == ["keeps"]


def test_extraction_recovers_from_a_fence_and_a_dropped_comma() -> None:
    """The installed mlx_lm.server constrains nothing (LOCAL13 leg 2), so every
    stage decodes unconstrained and the recovery ladder is load-bearing. The
    missing comma is the exact defect that cost a meeting on 2026-07-27."""
    fenced = '```json\n{"facts": [{"kind": "date", "text": "Friday"' \
        ' "who": null, "quote": "before Friday", "t": "0:30"}]}\n```'
    rows = staged.parse_facts(fenced)
    assert [row.text for row in rows] == ["Friday"]
    assert rows[0].t == 30.0


def test_extraction_caps_a_runaway_window() -> None:
    flood = {"facts": [
        {"kind": "artifact", "text": f"t{i}", "who": None, "quote": f"q{i}", "t": 0}
        for i in range(50)
    ]}
    assert len(staged.parse_facts(json.dumps(flood))) == staged._MAX_FACTS_PER_WINDOW


# ----- Stage 2: COMPOSE -----

def test_composition_sees_fact_rows_only_and_never_the_transcript() -> None:
    """The probe the acceptance criteria name. Stage 2's whole premise is that the
    abstraction burden moves onto short, dense, already-extracted context, so a
    composer that could still read the raw transcript would silently be the old
    single-pass shape wearing a new prompt."""
    script = _happy_script()
    assert _run(script) is not None

    turn_bodies = [text for _, _, text in _TURNS]
    for stage in ("summary", "decisions", "questions", "actions", "title"):
        blob = "\n".join(m["content"] for m in script.messages_for(stage))
        for body in turn_bodies:
            assert body not in blob, f"{stage} was shown a raw transcript turn"
        # The quotes themselves DO ride along, on the fact rows, which is the
        # point: they are what the composed point cites.
        assert "I will ship the hotfix to staging before Friday" in blob


def test_composition_prompts_share_a_cacheable_prefix() -> None:
    """LOCAL13 measured the single-pass preamble at 3,520 fixed tokens, so per-stage
    prompt size is a first-order cost. The five compose calls share a byte-stable
    leading block, and every per-stage schema is a fraction of the big one."""
    prompts = [staged.compose_system(s, "en") for s in
               ("summary", "decisions", "questions", "actions", "title")]
    assert all(p.startswith(staged._COMPOSE_PREAMBLE) for p in prompts)
    assert all(len(p) < 4_000 for p in prompts)
    # Volatile content last: the language directive is the tail, the facts are in
    # the user turn.
    assert all(p.rstrip().endswith("This overrides any default to English.") for p in prompts)


def test_composed_points_inherit_anchors_rather_than_retyping_them() -> None:
    """A composer cites rows by index, so it cannot invent a quote at this stage.
    It can cite the wrong row, and Stage 3 is what catches that."""
    facts = staged.parse_facts(_facts_reply())
    point = staged.parse_points(_points(("bullet", [0, 2])))[0]
    anchors = staged.anchors_for(point, facts)
    assert [a.quote for a in anchors] == [facts[0].quote, facts[2].quote]
    # An index nobody extracted contributes nothing rather than raising.
    assert staged.anchors_for(staged.ComposedPoint("x", (99,)), facts) == []


def test_composition_of_one_section_failing_leaves_the_others_alone() -> None:
    script = _happy_script()
    script.fail["questions"] = RuntimeError("server hiccup")
    summary = _run(script)
    assert summary is not None
    assert summary.questions == []
    assert summary.summary and summary.decisions


# ----- Stage 3: VERIFY -----

def test_verifier_drops_a_fabricated_quote() -> None:
    """A quote Stage 1 invented resolves against nothing, so the decision citing it
    has no surviving anchor and is dropped. Absence over a wrong citation."""
    invented = json.dumps({"facts": [
        {"kind": "commitment", "text": "made up", "who": "Alice",
         "quote": "we are migrating the whole estate to Kubernetes", "t": "0:30"},
    ]})
    script = _happy_script(
        extract=invented,
        summary=_points(("Something happened.", [0])),
        decisions=_points(("A decision built on an invented quote.", [0])),
        actions='{"items": []}',
    )
    summary = _run(script)
    assert summary is not None
    assert summary.decisions == []
    assert summary.evidence == {}


def test_verifier_drops_an_unresolvable_timestamp() -> None:
    """The quote is genuinely in the transcript, but nowhere near the cited time.
    A citation that lands on the wrong row is worse than none, so it goes."""
    misplaced = json.dumps({"facts": [
        {"kind": "commitment", "text": "real words, wrong minute", "who": "Alice",
         "quote": "I will ship the hotfix to staging before Friday", "t": "6:30"},
    ]})
    script = _happy_script(
        extract=misplaced,
        summary=_points(("Something happened.", [0])),
        decisions=_points(("Alice ships the hotfix.", [0])),
        actions='{"items": []}',
    )
    summary = _run(script)
    assert summary is not None
    assert summary.decisions == []


def test_verifier_drops_an_owner_with_no_supporting_quote() -> None:
    """Owner propagation (one name attached to every action because it was the only
    name around) is the single-pass path's worst owner failure. An owner survives
    only when a quote backing that action actually names them."""
    script = _happy_script(actions=json.dumps({"items": [
        {"task": "Ship the hotfix", "owner": "Alice", "due": None, "facts": [0]},
        {"task": "Draft the notes", "owner": "Alice", "due": None, "facts": [4]},
    ]}))
    summary = _run(script)
    assert summary is not None
    tasks = {a.task: a for a in summary.actions}
    assert tasks["Ship the hotfix"].owner == "Alice"
    # "I can draft the release notes" names nobody, and no cited row calls the
    # subject Alice, so the guess is dropped rather than forwarded to a sink.
    assert tasks["Draft the notes"].owner is None
    assert tasks["Draft the notes"].confidence == "low"


def test_verifier_drops_an_action_that_traces_to_nothing() -> None:
    script = _happy_script(actions=json.dumps({"items": [
        {"task": "Something nobody said", "owner": None, "due": None, "facts": []},
    ]}))
    summary = _run(script)
    assert summary is not None
    assert summary.actions == []


def test_verifier_dedupes_repeated_points() -> None:
    script = _happy_script(summary=_points(
        ("Alice ships the hotfix.", [0]),
        ("alice ships the hotfix", [0]),
        ("Carol drafts the notes.", [4]),
    ))
    summary = _run(script)
    assert summary is not None
    assert len(summary.summary) == 2


def test_owner_support_matching_is_case_and_script_tolerant() -> None:
    anchors = [Evidence(quote="Оксана бере на себе релізні нотатки", t=1.0)]
    assert staged.owner_is_supported("оксана", anchors, set())
    assert not staged.owner_is_supported("Bohdan", anchors, set())
    # A row that named the person as its subject counts too.
    assert staged.owner_is_supported("Bohdan", anchors, {"bohdan"})


# ----- Stage 3: the critic -----

def test_critic_drops_an_intention_that_survived_determinism() -> None:
    """The one thing determinism cannot judge. Both candidates below resolve to a
    real quote; only one of them is a commitment."""
    script = _happy_script(
        decisions=_points(
            ("Carol drafts the release notes.", [4]),
            ("The team will look at moving the nightly job.", [3]),
        ),
        critic='{"keep": [0]}',
    )
    summary = _run(script)
    assert summary is not None
    assert summary.decisions == ["Carol drafts the release notes."]


def test_an_unreadable_critic_keeps_every_decision() -> None:
    """A critic that cannot be read must never cost content that already passed
    the deterministic checks."""
    script = _happy_script(critic="I think probably the first one? Hard to say.")
    summary = _run(script)
    assert summary is not None
    assert len(summary.decisions) == 2


def test_a_failing_critic_call_keeps_every_decision() -> None:
    script = _happy_script()
    script.fail["critic"] = RuntimeError("server died")
    summary = _run(script)
    assert summary is not None
    assert len(summary.decisions) == 2


def test_critic_keeping_nothing_is_obeyed() -> None:
    """Empty and unreadable are different answers, and only one of them is the
    critic actually answering the question."""
    script = _happy_script(critic='{"keep": []}')
    summary = _run(script)
    assert summary is not None
    assert summary.decisions == []


# ----- Declining -----

def test_a_degenerate_transcript_short_circuits_to_the_single_pass_shape() -> None:
    """LOCAL2's territory. Below the floor there is nothing to extract and three
    calls cost more than one, so the staged path declines and the caller runs the
    shape that stays in the code exactly for this."""
    script = _happy_script()
    assert _run(script, transcript="[0:00] **Alice**: Hi.\n") is None
    assert script.calls == []


def test_extracting_nothing_declines_rather_than_composing_from_air() -> None:
    script = _happy_script(extract='{"facts": []}')
    assert _run(script) is None
    assert [stage for stage, _ in script.calls] == ["extract"]


def test_composing_no_summary_bullets_declines() -> None:
    script = _happy_script(summary='{"items": []}')
    assert _run(script) is None


def test_an_unexpected_failure_declines_rather_than_losing_the_meeting(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A bug in a path that is not even the default yet must cost a fallback, not
    the summary. The caller has a working single-pass shape right behind it, so
    the failure below is raised where none of the per-stage guards can see it."""
    def boom(_: str) -> list[dict[str, object]]:
        raise ValueError("something nobody anticipated")

    monkeypatch.setattr(staged, "segments_from_timestamped_markdown", boom)
    assert _run(_happy_script()) is None


def test_one_failing_extract_window_does_not_sink_the_run() -> None:
    """Extraction is the map; a map that loses one slice still composes from the
    rest. The long transcript here is what forces more than one window."""
    long_transcript = _transcript(repeat=10)
    assert len(long_transcript) > staged.window_chars(long_transcript)

    script = _happy_script()
    seen = {"n": 0}
    inner = script.__call__

    def flaky(*, messages, max_tokens, response_format=None):
        if messages[0]["content"].startswith("You extract"):
            seen["n"] += 1
            if seen["n"] == 2:
                raise RuntimeError("window 2 timed out")
        return inner(messages=messages, max_tokens=max_tokens, response_format=response_format)

    summary = staged.run_staged(
        chat=flaky, transcript=long_transcript, target="en", max_tokens=4000
    )
    assert seen["n"] > 1
    assert summary is not None and summary.summary


# ----- Assembly -----

def test_attendees_and_language_are_derived_not_asked_for() -> None:
    """Neither buys anything a deterministic read of the fact rows does not already
    have, so neither costs a model call."""
    summary = _run(_happy_script())
    assert summary is not None
    assert set(summary.attendees) == {"Alice", "Bob", "Carol"}
    assert summary.detected_language == "en"


def test_a_missing_title_falls_back_to_the_first_bullet() -> None:
    script = _happy_script(title="sorry, I could not think of one")
    summary = _run(script)
    assert summary is not None
    assert summary.title == "Alice takes the hotfix to staging before Friday."


def test_surviving_anchors_are_snapped_to_the_cited_turn() -> None:
    """Same rule the FEAT10 verifier applies downstream, run one step earlier, so a
    chip click lands on the cited row rather than near it."""
    summary = _run(_happy_script())
    assert summary is not None
    anchors = summary.evidence["summary"][0]
    assert anchors and anchors[0].t == 30.0
    assert anchors[0].quote == "I will ship the hotfix to staging before Friday"


# ----- Segment recovery (the seam Stage 3 verifies against) -----

def test_segments_recovered_from_the_timestamped_render() -> None:
    segments = segments_from_timestamped_markdown(TRANSCRIPT)
    assert len(segments) == len(_TURNS)
    assert segments[0]["start"] == 0.0
    assert segments[1]["start"] == 30.0
    # A turn spans until the next one begins, so a quote from late in a long turn
    # still resolves inside it.
    assert segments[0]["end"] == 30.0
    # The header and the language note are not things anyone said.
    assert all("Language detected" not in s["text"] for s in segments)


def test_segment_recovery_reads_the_hour_form() -> None:
    md = "[1:05:30] **Alice**: much later in a long meeting\n"
    assert segments_from_timestamped_markdown(md)[0]["start"] == 3930.0


# ----- End to end through the fake mlx_lm.server -----

@pytest.fixture
def staged_server(monkeypatch: pytest.MonkeyPatch):
    """The same in-process fake `mlx_lm.server` the single-pass tests use, with the
    LOCAL14 toggle on, so the whole path runs over real HTTP without a model."""
    monkeypatch.setenv(staged.STAGED_ENV, "1")
    server = ThreadingHTTPServer(("127.0.0.1", 0), _FakeHandler)
    script = _happy_script()

    def builder(body: dict) -> dict:
        reply = script(
            messages=body["messages"],
            max_tokens=body.get("max_tokens", 0),
            response_format=body.get("response_format"),
        )
        return {"choices": [{"message": {"content": reply}}]}

    server.builder = builder  # type: ignore[attr-defined]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    host, port = server.server_address[0], server.server_address[1]
    yield host, port, script
    server.shutdown()
    server.server_close()


def test_staged_path_runs_end_to_end_over_the_fake_server(staged_server) -> None:
    host, port, script = staged_server
    with LocalSummaryClient(host=host, port=port, manage_subprocess=False) as client:
        summary = client.summarize(
            system_prompt="master prompt", transcript=TRANSCRIPT,
            model="ignored", max_tokens=4000,
        )
    stages = [stage for stage, _ in script.calls]
    assert stages[0] == "extract"
    assert set(stages[1:]) == {"summary", "decisions", "questions", "actions", "critic", "title"}
    assert summary.title == "Release window standup"
    assert len(summary.summary) == 2
    assert summary.actions[0].owner == "Alice"
    assert summary.evidence["summary"][0][0].t == 30.0
    # The one giant schema never went over the wire on this path; per-stage minimal
    # schemas replaced it (LOCAL13: the single-pass preamble is 3,520 fixed tokens).
    for _, messages in script.calls:
        assert "emit_meeting_summary" not in messages[0]["content"]


def test_the_toggle_off_keeps_the_single_pass_shape(staged_server, monkeypatch) -> None:
    """The default is unchanged, and this is the test that says so."""
    host, port, script = staged_server
    monkeypatch.delenv(staged.STAGED_ENV, raising=False)
    with LocalSummaryClient(host=host, port=port, manage_subprocess=False) as client:
        with pytest.raises(Exception):
            # The scripted server only knows the staged prompts, so a single-pass
            # call reaching it is exactly what the assertion below detects.
            client.summarize(
                system_prompt="master prompt", transcript=TRANSCRIPT,
                model="ignored", max_tokens=4000,
            )
    assert script.calls == []
