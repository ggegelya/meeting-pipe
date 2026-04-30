"""Centralised external-service URLs and identifiers.

Single source of truth for every host, API path, model name, or signup URL
used by the pipeline. Keeping these out of business logic means a service
move (e.g. Notion bumping API version, pyannote releasing v4) is a one-file
change, and any test that needs to monkeypatch a URL has a single import to
target.

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

# --- HuggingFace + pyannote --------------------------------------------------
HF_API_BASE = "https://huggingface.co/api"
HF_API_WHOAMI = f"{HF_API_BASE}/whoami-v2"
HF_API_MODEL_TEMPLATE = f"{HF_API_BASE}/models/{{repo}}"
HF_TOKENS_URL = "https://huggingface.co/settings/tokens"
HF_MODEL_PAGE_TEMPLATE = "https://huggingface.co/{repo}"

PYANNOTE_DIARIZATION_REPO = "pyannote/speaker-diarization-3.1"
PYANNOTE_SEGMENTATION_REPO = "pyannote/segmentation-3.0"
PYANNOTE_GATED_REPOS: tuple[str, ...] = (
    PYANNOTE_DIARIZATION_REPO,
    PYANNOTE_SEGMENTATION_REPO,
)


def hf_model_api_url(repo: str) -> str:
    return HF_API_MODEL_TEMPLATE.format(repo=repo)


def hf_model_page_url(repo: str) -> str:
    return HF_MODEL_PAGE_TEMPLATE.format(repo=repo)


def notion_page_url(page_id: str) -> str:
    return NOTION_PAGE_URL_TEMPLATE.format(page_id_no_dashes=page_id.replace("-", ""))
