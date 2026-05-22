"""Sanity-check that endpoint constants are non-empty and well-formed.

Cheap regression guard: if a future refactor accidentally blanks one of
these or breaks the URL-template helpers, this fails fast in CI rather
than at runtime against the real Notion / HuggingFace APIs.
"""
from __future__ import annotations

import pytest

from mp import endpoints as E


@pytest.mark.parametrize(
    "name",
    [
        "ANTHROPIC_API_BASE",
        "ANTHROPIC_API_VERSION",
        "ANTHROPIC_CONSOLE_KEYS_URL",
        "ANTHROPIC_DOCTOR_PROBE_MODEL",
        "ANTHROPIC_MESSAGES_PATH",
        "NOTION_API_BASE",
        "NOTION_API_VERSION",
        "NOTION_INTEGRATIONS_URL",
        "HF_API_BASE",
        "HF_API_WHOAMI",
        "HF_TOKENS_URL",
    ],
)
def test_constant_is_non_empty_string(name: str) -> None:
    val = getattr(E, name)
    assert isinstance(val, str)
    assert val.strip(), f"{name} is blank"


def test_notion_page_url_strips_dashes() -> None:
    page_id = "11111111-2222-3333-4444-555555555555"
    url = E.notion_page_url(page_id)
    assert "-" not in url.split("notion.so/")[-1]
    assert url.endswith("11111111222233334444555555555555")
