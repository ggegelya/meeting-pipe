"""Tests for summarize.py — mock the Anthropic client to avoid network calls."""
from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import MagicMock, patch

import anthropic
import httpx
import pytest

from mp.config import Config, Recording
from mp.markdown import render_summary_md
from mp.summarize import (
    _load_system_prompt,
    _prior_meeting_context,
    _summary_language_directive,
    summarize,
)
from mp.schemas import ActionItem, MeetingSummary


def _make_summary() -> MeetingSummary:
    return MeetingSummary(
        title="Phase 6 sync",
        summary=["Reviewed Notion publishing schema", "Confirmed regulated mode"],
        decisions=["We will ship Friday."],
        actions=[
            ActionItem(task="Update SOP", owner="Alice", due="2026-05-01", confidence="high"),
            ActionItem(task="Investigate diarization for UA", owner=None, confidence="low"),
        ],
        questions=["Should we cap transcript size?"],
        attendees=["Alice", "Bob"],
        detected_language="en",
    )


def test_render_summary_md_has_all_sections():
    md = render_summary_md(_make_summary())
    assert "# Phase 6 sync" in md
    assert "**Attendees:** Alice, Bob" in md
    assert "## Summary" in md
    assert "## Decisions" in md
    assert "## Action Items" in md
    assert "## Open Questions" in md
    assert "_unassigned_" in md
    assert "due 2026-05-01" in md


def test_summarize_calls_anthropic_and_writes_outputs(tmp_path: Path, monkeypatch):
    transcript = tmp_path / "20260428-1200.md"
    transcript.write_text(
        "# Transcript\n\n**A**: Hi.\n\n**B**: We will ship Friday.\n",
        encoding="utf-8",
    )

    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")

    fake_summary = _make_summary()

    # Mock the SDK response so the test doesn't hit the network.
    fake_tool_block = MagicMock()
    fake_tool_block.type = "tool_use"
    fake_tool_block.input = fake_summary.model_dump()

    fake_response = MagicMock()
    fake_response.content = [fake_tool_block]
    fake_response.stop_reason = "tool_use"

    fake_client = MagicMock()
    fake_client.messages.create.return_value = fake_response

    cfg = Config()  # defaults

    with patch("mp.summarize.anthropic.Anthropic", return_value=fake_client):
        out = summarize(transcript, cfg=cfg)

    assert out["json"].exists()
    assert out["md"].exists()

    parsed = MeetingSummary.model_validate_json(out["json"].read_text(encoding="utf-8"))
    assert parsed.title == "Phase 6 sync"
    assert parsed.actions[0].owner == "Alice"

    # Confirm the API was called with tool_choice forcing the schema.
    call = fake_client.messages.create.call_args
    assert call.kwargs["tool_choice"]["name"] == "emit_meeting_summary"
    assert call.kwargs["tools"][0]["name"] == "emit_meeting_summary"


def test_summarize_repairs_divergent_cloud_language(tmp_path: Path, monkeypatch):
    """LANG1: the cloud path now verifies its own output. An all-English transcript
    whose first summary comes back with a Russian action + question block is
    detected and repaired in one extra call; the clean repair is what gets written.
    Uses an injected client, so no backend-specific mechanism is involved: this is
    the backend-agnostic post-hoc check in `summarize()` itself."""
    transcript = tmp_path / "20260707-123334.md"
    transcript.write_text(
        "# Transcript\n\n**A**: Let us review the sprint scope and the release plan.\n\n"
        "**B**: We agreed to ship the migration on Friday after the regression pass.\n",
        encoding="utf-8",
    )
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")

    drifted = MeetingSummary(
        title="Sprint review sync",
        summary=["Reviewed the sprint scope and the release plan."],
        decisions=["We will ship the migration on Friday."],
        actions=[ActionItem(
            task="Подготовить отчёт о регрессионном тестировании к пятнице.", owner=None,
        )],
        questions=["Нужно ли ограничивать размер расшифровки стенограммы?"],
        attendees=["A", "B"],
        detected_language="en",
    )
    clean = _make_summary()

    class _FakeClient:
        def __init__(self) -> None:
            self.calls = 0

        def summarize(self, *, system_prompt, transcript, model, max_tokens):
            self.calls += 1
            return drifted if self.calls == 1 else clean

    client = _FakeClient()
    out = summarize(transcript, cfg=Config(), client=client)
    assert client.calls == 2, "a divergent cloud summary must be repaired exactly once"
    written = MeetingSummary.model_validate_json(out["json"].read_text(encoding="utf-8"))
    # The clean repair was kept, not the drifted first pass.
    assert written.title == "Phase 6 sync"


def test_summarize_applies_speaker_overlay(tmp_path: Path, monkeypatch):
    """FEAT3-UNDO/SEGMENT: a regenerate applies the daemon's speaker-label overlay to
    the transcript fed to the model, so the summary + attendees reflect in-app names."""
    stem = "20260101-0900"
    (tmp_path / f"{stem}.json").write_text(
        json.dumps({"language": "en", "segments": [
            {"start": 0.0, "end": 1.0, "text": "let us start the review", "speaker": "THEM-A"},
        ]}),
        encoding="utf-8",
    )
    md = tmp_path / f"{stem}.md"
    md.write_text("# Transcript\n\n**THEM-A**: let us start the review\n", encoding="utf-8")
    (tmp_path / f"{stem}.speaker_labels.json").write_text(
        json.dumps({"labels": {"THEM-A": "Alice"}, "segments": {}}), encoding="utf-8"
    )
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")

    seen: dict = {}

    class _FakeClient:
        def summarize(self, *, system_prompt, transcript, model, max_tokens):
            seen["transcript"] = transcript
            return _make_summary()

    summarize(md, cfg=Config(), client=_FakeClient())
    assert "Alice" in seen["transcript"]
    assert "THEM-A" not in seen["transcript"]


def test_summarize_no_repair_when_language_matches(tmp_path: Path, monkeypatch):
    """The post-hoc check must not over-fire: an on-target summary is returned
    without a second call."""
    transcript = tmp_path / "x.md"
    transcript.write_text(
        "# Transcript\n\n**A**: We reviewed the plan and agreed to ship on Friday.\n",
        encoding="utf-8",
    )
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")

    class _FakeClient:
        def __init__(self) -> None:
            self.calls = 0

        def summarize(self, **_):
            self.calls += 1
            return _make_summary()

    client = _FakeClient()
    summarize(transcript, cfg=Config(), client=client)
    assert client.calls == 1, "a matching language must not trigger a repair call"


def test_summarize_retries_on_schema_violation(tmp_path: Path, monkeypatch):
    transcript = tmp_path / "x.md"
    transcript.write_text("# Transcript\n\n**A**: Hi.\n", encoding="utf-8")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")

    bad_block = MagicMock()
    bad_block.type = "tool_use"
    bad_block.input = {"title": "incomplete"}  # missing required fields

    good_block = MagicMock()
    good_block.type = "tool_use"
    good_block.input = _make_summary().model_dump()

    bad = MagicMock(content=[bad_block], stop_reason="tool_use")
    good = MagicMock(content=[good_block], stop_reason="tool_use")

    fake_client = MagicMock()
    fake_client.messages.create.side_effect = [bad, good]

    with patch("mp.summarize.anthropic.Anthropic", return_value=fake_client):
        summarize(transcript, cfg=Config())

    assert fake_client.messages.create.call_count == 2


def _rate_limit_error() -> anthropic.RateLimitError:
    """Construct a RateLimitError without hitting the network.

    The anthropic SDK constructor takes (message, response, body); we pass a
    minimal httpx.Response with the right status code.
    """
    response = httpx.Response(status_code=429, request=httpx.Request("POST", "https://api.anthropic.com/v1/messages"))
    return anthropic.RateLimitError(
        message="rate limited",
        response=response,
        body={"type": "error", "error": {"type": "rate_limit_error", "message": "x"}},
    )


def test_summarize_retries_on_rate_limit(tmp_path: Path, monkeypatch):
    """Tenacity should retry RateLimitError and succeed once the API recovers."""
    transcript = tmp_path / "x.md"
    transcript.write_text("# Transcript\n\n**A**: Hi.\n", encoding="utf-8")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")

    # Make tenacity's wait near-zero so the test runs in milliseconds.
    monkeypatch.setattr("mp.summarize._create_message.retry.wait", lambda *_a, **_k: 0)

    good_block = MagicMock(type="tool_use", input=_make_summary().model_dump())
    good_response = MagicMock(content=[good_block], stop_reason="tool_use")

    fake_client = MagicMock()
    fake_client.messages.create.side_effect = [
        _rate_limit_error(),
        _rate_limit_error(),
        good_response,
    ]

    with patch("mp.summarize.anthropic.Anthropic", return_value=fake_client):
        summarize(transcript, cfg=Config())

    # 2 rate-limited attempts + 1 success = 3 total
    assert fake_client.messages.create.call_count == 3


def test_auto_language_directive_tells_model_to_match_transcript():
    """The default `summary_language=auto` should instruct the model to
    write output in the transcript's own language — Russian transcript →
    Russian summary, etc."""
    directive = _summary_language_directive("auto")
    assert "SAME language as the transcript" in directive
    # Sanity-check the example clause survived (multi-language guidance).
    assert "Russian" in directive


def test_explicit_language_directive_overrides_to_iso_code():
    """An ISO 639-1 code in the config forces the model to ignore the
    transcript language and produce the summary in the configured one."""
    directive = _summary_language_directive("en")
    assert "language `en`" in directive
    assert "regardless" in directive


def test_unknown_language_value_falls_back_to_auto():
    """Bad config (e.g. `summary_language = "english"` typed in by the
    user) should NOT confuse the model. Fall through to auto behavior."""
    directive = _summary_language_directive("english")
    assert "SAME language as the transcript" in directive


def test_load_system_prompt_substitutes_language_directive():
    """End-to-end: the placeholder `{summary_language_directive}` in the
    prompt file is replaced by the resolved directive — ensures we don't
    ship an unresolved placeholder to the model."""
    prompt = _load_system_prompt("acme regulated SaaS", summary_language="ru")
    assert "{summary_language_directive}" not in prompt
    assert "language `ru`" in prompt
    # team_context placeholder still resolves correctly alongside the new one.
    assert "acme regulated SaaS" in prompt


def test_summarize_does_not_retry_on_bad_request(tmp_path: Path, monkeypatch):
    """4xx (other than 429) is a caller bug — fail fast, don't retry."""
    transcript = tmp_path / "x.md"
    transcript.write_text("# Transcript\n\n**A**: Hi.\n", encoding="utf-8")
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test")

    response = httpx.Response(
        status_code=400,
        request=httpx.Request("POST", "https://api.anthropic.com/v1/messages"),
    )
    bad_request = anthropic.BadRequestError(
        message="bad",
        response=response,
        body={"type": "error", "error": {"type": "invalid_request_error", "message": "x"}},
    )

    fake_client = MagicMock()
    fake_client.messages.create.side_effect = bad_request

    with patch("mp.summarize.anthropic.Anthropic", return_value=fake_client):
        with pytest.raises(anthropic.BadRequestError):
            summarize(transcript, cfg=Config())

    # Single call, no retries.
    assert fake_client.messages.create.call_count == 1


class _FixedClient:
    """Injected summary client that returns a canned summary, no network."""

    def summarize(self, *, system_prompt, transcript, model, max_tokens):
        return _make_summary()


def test_summarize_candidate_suffix_writes_preview_without_touching_live(tmp_path: Path):
    # TECH-A16: --candidate / out_suffix writes a preview sidecar and leaves the
    # live summary.json untouched (the local re-run preview path).
    transcript = tmp_path / "20260428-1200.md"
    transcript.write_text("# Transcript\n\n**A**: Hi.\n", encoding="utf-8")

    out = summarize(transcript, cfg=Config(), client=_FixedClient(), out_suffix="candidate")

    assert out["json"].name == "20260428-1200.summary.candidate.json"
    assert out["md"].name == "20260428-1200.summary.candidate.md"
    assert out["json"].exists() and out["md"].exists()
    assert not (tmp_path / "20260428-1200.summary.json").exists()
    parsed = MeetingSummary.model_validate_json(out["json"].read_text(encoding="utf-8"))
    assert parsed.title == "Phase 6 sync"


def test_summarize_default_writes_live_sidecars(tmp_path: Path):
    transcript = tmp_path / "x.md"
    transcript.write_text("# Transcript\n\n**A**: Hi.\n", encoding="utf-8")

    out = summarize(transcript, cfg=Config(), client=_FixedClient())

    assert out["json"].name == "x.summary.json"
    assert out["md"].name == "x.summary.md"


class _CapturingClient:
    """Injected client that records the system prompt + transcript, no network."""

    def __init__(self) -> None:
        self.system_prompt: str | None = None
        self.transcript: str | None = None

    def summarize(self, *, system_prompt, transcript, model, max_tokens):
        self.system_prompt = system_prompt
        self.transcript = transcript
        return _make_summary()


def test_context_override_replaces_team_context_for_this_run(tmp_path: Path, monkeypatch):
    # TECH-FEAT7: MP_CONTEXT_OVERRIDE replaces only the CONTEXT block value for
    # this run; the configured team_context is not used and cfg is not mutated.
    transcript = tmp_path / "x.md"
    transcript.write_text("# Transcript\n\n**A**: Hi.\n", encoding="utf-8")
    monkeypatch.setenv("MP_CONTEXT_OVERRIDE", "FOCUS_ON_DECISIONS_AND_OWNERS")

    cfg = Config()
    cfg.summarization.team_context = "CONFIGURED_TEAM_CONTEXT"
    client = _CapturingClient()
    summarize(transcript, cfg=cfg, client=client)

    assert client.system_prompt is not None
    assert "FOCUS_ON_DECISIONS_AND_OWNERS" in client.system_prompt
    assert "CONFIGURED_TEAM_CONTEXT" not in client.system_prompt
    # Request-scoped: the override never mutates the config.
    assert cfg.summarization.team_context == "CONFIGURED_TEAM_CONTEXT"


def test_empty_context_override_is_a_noop(tmp_path: Path, monkeypatch):
    # A whitespace-only override falls back to the configured context: a plain reprocess.
    transcript = tmp_path / "x.md"
    transcript.write_text("# Transcript\n\n**A**: Hi.\n", encoding="utf-8")
    monkeypatch.setenv("MP_CONTEXT_OVERRIDE", "   ")

    cfg = Config()
    cfg.summarization.team_context = "CONFIGURED_TEAM_CONTEXT"
    client = _CapturingClient()
    summarize(transcript, cfg=cfg, client=client)

    assert client.system_prompt is not None
    assert "CONFIGURED_TEAM_CONTEXT" in client.system_prompt


def test_no_context_override_uses_configured_context(tmp_path: Path, monkeypatch):
    # With no env var set, behaviour is exactly as before FEAT7.
    transcript = tmp_path / "x.md"
    transcript.write_text("# Transcript\n\n**A**: Hi.\n", encoding="utf-8")
    monkeypatch.delenv("MP_CONTEXT_OVERRIDE", raising=False)

    cfg = Config()
    cfg.summarization.team_context = "CONFIGURED_TEAM_CONTEXT"
    client = _CapturingClient()
    summarize(transcript, cfg=cfg, client=client)

    assert client.system_prompt is not None
    assert "CONFIGURED_TEAM_CONTEXT" in client.system_prompt


# --- AI6: recurring-series continuity ---------------------------------------

def _write_prior_meeting(root: Path, stem: str, *, workflow_id: str, summary: MeetingSummary) -> None:
    (root / f"{stem}.summary.json").write_text(summary.model_dump_json(), encoding="utf-8")
    (root / f"{stem}.meta.json").write_text(
        json.dumps({"workflow_id": workflow_id, "workflow_name": "Weekly"}), encoding="utf-8"
    )


def _current_meeting(root: Path, stem: str, *, workflow_id: str, workflow_name: str = "Weekly") -> Path:
    md = root / f"{stem}.md"
    md.write_text("# Transcript\n\n**A**: Hi.\n", encoding="utf-8")
    (root / f"{stem}.meta.json").write_text(
        json.dumps({"workflow_id": workflow_id, "workflow_name": workflow_name}), encoding="utf-8"
    )
    return md


def test_ai6_injects_prior_decisions_and_open_actions(tmp_path: Path):
    prior = MeetingSummary(
        title="Weekly sync #1",
        summary=["s"],
        decisions=["Adopt the new deploy process."],
        actions=[
            ActionItem(task="Draft the migration doc", owner="Alice", due="2026-07-01",
                       confidence="high", resolved=False),
            ActionItem(task="Close the old ticket", owner="Bob", confidence="high", resolved=True),
        ],
        detected_language="en",
    )
    _write_prior_meeting(tmp_path, "20260701-1000", workflow_id="wf-1", summary=prior)
    md = _current_meeting(tmp_path, "20260708-1000", workflow_id="wf-1")

    client = _CapturingClient()
    summarize(md, cfg=Config(recording=Recording(output_dir=tmp_path)), client=client)

    sp = client.system_prompt
    assert sp is not None
    assert "Previous meeting in this series" in sp
    assert "Adopt the new deploy process." in sp   # carried decision
    assert "Draft the migration doc" in sp         # still-open action
    assert "Close the old ticket" not in sp        # resolved action is excluded


def test_ai6_first_meeting_in_workflow_is_a_noop(tmp_path: Path):
    md = _current_meeting(tmp_path, "20260708-0900", workflow_id="wf-lonely")
    client = _CapturingClient()
    summarize(md, cfg=Config(recording=Recording(output_dir=tmp_path)), client=client)
    assert client.system_prompt is not None
    assert "Previous meeting in this series" not in client.system_prompt


def test_ai6_ignores_priors_from_other_workflows(tmp_path: Path):
    _write_prior_meeting(tmp_path, "20260701-1000", workflow_id="wf-other", summary=_make_summary())
    md = _current_meeting(tmp_path, "20260708-1000", workflow_id="wf-mine", workflow_name="Mine")
    client = _CapturingClient()
    summarize(md, cfg=Config(recording=Recording(output_dir=tmp_path)), client=client)
    assert client.system_prompt is not None
    assert "Previous meeting in this series" not in client.system_prompt


def test_ai6_picks_the_latest_prior_meeting(tmp_path: Path):
    older = MeetingSummary(title="old", summary=["s"], decisions=["Old decision."], detected_language="en")
    newer = MeetingSummary(title="Recent sync", summary=["s"], decisions=["Newer decision."],
                           detected_language="en")
    _write_prior_meeting(tmp_path, "20260601-1000", workflow_id="wf-1", summary=older)
    _write_prior_meeting(tmp_path, "20260701-1000", workflow_id="wf-1", summary=newer)
    md = _current_meeting(tmp_path, "20260708-1000", workflow_id="wf-1")

    ctx = _prior_meeting_context(md, Config(recording=Recording(output_dir=tmp_path)))
    assert ctx is not None
    assert "Newer decision." in ctx
    assert "Recent sync" in ctx
    assert "Old decision." not in ctx


# --- FEAT8: flagged moments reach the summarizer -----------------------------

def _write_transcript_with_markers(root: Path, stem: str, *, segments, marker_offsets) -> Path:
    md = root / f"{stem}.md"
    md.write_text("# Transcript\n\n**A**: Hi.\n", encoding="utf-8")
    (root / f"{stem}.json").write_text(json.dumps({"segments": segments}), encoding="utf-8")
    if marker_offsets is not None:
        (root / f"{stem}.markers.json").write_text(
            json.dumps({"schema_version": 1, "markers": [{"t_seconds": t} for t in marker_offsets]}),
            encoding="utf-8",
        )
    return md


def test_feat8_flagged_excerpt_and_instruction_reach_the_prompt(tmp_path: Path):
    from mp.markers import FLAGGED_INSTRUCTION

    segments = [
        {"start": 0.0, "end": 10.0, "text": "Casual opener.", "speaker": "A"},
        {"start": 10.0, "end": 20.0, "text": "Decision: migrate to Postgres.", "speaker": "B"},
    ]
    md = _write_transcript_with_markers(tmp_path, "20260707-1300", segments=segments, marker_offsets=[12.0])

    client = _CapturingClient()
    summarize(md, cfg=Config(recording=Recording(output_dir=tmp_path)), client=client)

    # Deterministic capture: the spanning segment's text rides in the transcript.
    assert client.transcript is not None
    assert "User-flagged moments" in client.transcript
    assert "Decision: migrate to Postgres." in client.transcript
    # Model-side emphasis: the trusted instruction is in the system prompt.
    assert client.system_prompt is not None
    assert FLAGGED_INSTRUCTION in client.system_prompt


def test_feat8_no_markers_leaves_prompt_unflagged(tmp_path: Path):
    from mp.markers import FLAGGED_INSTRUCTION

    segments = [{"start": 0.0, "end": 10.0, "text": "Just talking.", "speaker": "A"}]
    md = _write_transcript_with_markers(tmp_path, "20260707-1400", segments=segments, marker_offsets=None)

    client = _CapturingClient()
    summarize(md, cfg=Config(recording=Recording(output_dir=tmp_path)), client=client)

    assert "User-flagged moments" not in (client.transcript or "")
    assert FLAGGED_INSTRUCTION not in (client.system_prompt or "")
