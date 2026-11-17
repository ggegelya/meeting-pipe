"""Does the cloud provider know this model id? (PIPE28)

The model id is free text, and the only thing that ever checked it was the run that
failed on it. `GET /v1/models/{id}` is unbilled and answers 404 for an id that does
not exist, so `mp doctor` and the Preferences model field both ask it, and nothing
here sends a transcript. A pure verdict, not a failure: a network error or a rate
limit is `inconclusive`, never `not_found`, so a bad connection cannot tell the
owner their model is gone.
"""
from __future__ import annotations

import os
import sys
from typing import Literal
from urllib.parse import quote

import httpx

from .endpoints import ANTHROPIC_API_BASE, ANTHROPIC_API_VERSION, ANTHROPIC_MODELS_PATH

Verdict = Literal["found", "not_found", "inconclusive"]


def check_anthropic_model(model_id: str, api_key: str, *, timeout: float = 10.0) -> Verdict:
    try:
        resp = httpx.get(
            f"{ANTHROPIC_API_BASE}{ANTHROPIC_MODELS_PATH}/{quote(model_id, safe='')}",
            headers={"x-api-key": api_key, "anthropic-version": ANTHROPIC_API_VERSION},
            timeout=timeout,
        )
    except httpx.HTTPError:
        return "inconclusive"
    if resp.status_code == 200:
        return "found"
    if resp.status_code == 404:
        return "not_found"
    return "inconclusive"


def main(argv: list[str]) -> int:
    """`mp check-model <model-id>`: prints one JSON line `{"model": ..., "verdict": ...}`.

    The daemon's Preferences field runs this off the main thread when a new id is
    committed (the key stays in the pipeline's environment; Swift never holds it).
    Always exits 0: the verdict is the answer, and a missing key is `inconclusive`.
    """
    import json

    from . import entry
    from .config import Config

    if len(argv) != 1 or not argv[0].strip():
        print("usage: mp check-model <model-id>", file=sys.stderr)
        return 2
    model_id = argv[0].strip()
    cfg = entry.prepare(Config.load(), None)
    verdict: Verdict = "inconclusive"
    key = os.environ.get("ANTHROPIC_API_KEY", "")
    # Zero-egress: this would egress, so it never runs there, exactly like doctor's live probes.
    if key and not cfg.modes.regulated_mode:
        verdict = check_anthropic_model(model_id, key)
    print(json.dumps({"model": model_id, "verdict": verdict}))
    return 0
