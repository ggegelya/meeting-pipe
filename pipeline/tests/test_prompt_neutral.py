"""PIPE26: the shipped base prompt and example config describe no particular team.

The base prompt used to open as a "regulated-domain" summarizer, name the owner's
colleagues in its worked examples and hard-code a regulated-SaaS term list, and
`config.example.toml` shipped an FDA Part 11 `team_context` that the workflow
migrator copied into every fresh install's default workflow.
"""

from __future__ import annotations

import tomllib
from importlib import resources
from pathlib import Path

from mp.summarize import _load_system_prompt

REPO = Path(__file__).resolve().parents[2]

# Every hard-rule heading the prompt carried before PIPE26: only the intended lines moved.
HARD_RULE_HEADINGS = [
    "1. **No inventions.**",
    "2. **Decision = explicit commitment language.**",
    "3. **Action item discipline.**",
    "4. **Domain awareness.**",
    "5. **Open questions are part of the contract.**",
    "6. **Length cap.**",
    "7. **Title.**",
    "8. **Language detection.**",
    "9. **Attendees.**",
    "10. **Evidence.**",
]


def _raw_prompt() -> str:
    return resources.files("mp.prompts").joinpath("meeting_summary.md").read_text(encoding="utf-8")


def test_base_prompt_names_no_domain_and_no_colleague():
    text = _raw_prompt()
    for word in ("regulated", "Part 11", "FDA", "QMS", "Olenka", "Max approved"):
        assert word.lower() not in text.lower(), word


def test_rendered_prompt_keeps_every_hard_rule_heading():
    prompt = _load_system_prompt("")
    for heading in HARD_RULE_HEADINGS:
        assert heading in prompt, heading
    assert "## Hard rules" in prompt
    assert "## Output" in prompt


def test_rule_four_defers_domain_terms_to_the_team_context():
    text = _raw_prompt()
    rule = next(line for line in text.splitlines() if line.startswith("4. **Domain awareness.**"))
    assert "team context" in rule


def test_example_config_ships_an_empty_team_context():
    with (REPO / "config.example.toml").open("rb") as fh:
        doc = tomllib.load(fh)
    assert doc["summarization"]["team_context"] == ""
