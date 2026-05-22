"""Centralised external-service URLs and identifiers.

Single source of truth for every host, API path, model name, or signup URL
used by the pipeline. Keeping these out of business logic means a service
move (e.g. Notion bumping its API version) is a one-file change, and any
test that needs to monkeypatch a URL has a single import to target.

Constants only. Anything that needs runtime data (auth header construction,
URL formatting) belongs in the caller; constants stay pure.
"""
from __future__ import annotations

# --- Anthropic ---------------------------------------------------------------
ANTHROPIC_API_BASE = "https://api.anthropic.com/v1"
ANTHROPIC_MESSAGES_PATH = "/messages"
ANTHROPIC_API_VERSION = "2023-06-01"
ANTHROPIC_CONSOLE_KEYS_URL = "https://console.anthropic.com/settings/keys"
ANTHROPIC_DOCTOR_PROBE_MODEL = "claude-haiku-4-5-20251001"

# --- Notion ------------------------------------------------------------------
NOTION_API_BASE = "https://api.notion.com/v1"
NOTION_API_VERSION = "2022-06-28"
NOTION_INTEGRATIONS_URL = "https://www.notion.so/profile/integrations"
NOTION_PAGE_URL_TEMPLATE = "https://www.notion.so/{page_id_no_dashes}"

# --- HuggingFace -------------------------------------------------------------
# `mp doctor` validates an optional HF token (only relevant if the user
# opts back into pyannote diarization); diarization itself runs in the
# Swift daemon via FluidAudio, so the pyannote repo IDs and model-URL
# helpers no longer live here.
HF_API_BASE = "https://huggingface.co/api"
HF_API_WHOAMI = f"{HF_API_BASE}/whoami-v2"
HF_TOKENS_URL = "https://huggingface.co/settings/tokens"


def notion_page_url(page_id: str) -> str:
    return NOTION_PAGE_URL_TEMPLATE.format(page_id_no_dashes=page_id.replace("-", ""))
