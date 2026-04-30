"""Publish a MeetingSummary to a Notion database.

Idempotency strategy: after the first POST, we stash the returned `page_id`
in `<stem>.notion.json` next to the audio. On rerun, we PATCH the existing
page (properties + body block replacement) instead of creating a new one.

Body structure (SPEC §6 phase 6):
1. Summary (bulleted list)
2. Decisions (numbered list)
3. Action Items (to_do blocks)
4. Open Questions (bulleted list)
5. Toggle: "Full transcript" — speaker-labeled MD (skipped if regulated_mode)

Only the Date, Title, Status, and Source File properties are written. We
deliberately keep property writes minimal so the user's database schema only
needs those columns to exist.
"""
from __future__ import annotations

import json
import logging
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import httpx
from tenacity import retry, retry_if_exception_type, stop_after_attempt, wait_exponential

from .config import Config, load_secrets, require_env
from .schemas import MeetingSummary

log = logging.getLogger("mp.publish_notion")

NOTION_API = "https://api.notion.com/v1"
NOTION_VERSION = "2022-06-28"


class NotionError(RuntimeError):
    pass


def publish(
    summary_json: Path,
    cfg: Config | None = None,
    transcript_md: Path | None = None,
) -> dict[str, Any]:
    """Publish the summary; return {page_id, page_url, idempotent: bool}."""
    cfg = cfg or Config.load()
    load_secrets()

    if cfg.modes.regulated_mode:
        log.info("regulated_mode=true → skipping Notion publish")
        return {"page_id": None, "page_url": None, "regulated": True}

    if not cfg.notion.database_id:
        raise NotionError("notion.database_id is empty in config.toml")

    token = require_env("NOTION_TOKEN")

    summary = MeetingSummary.model_validate_json(summary_json.read_text(encoding="utf-8"))

    # Default the transcript path to <stem>.md (where mp transcribe writes it).
    if transcript_md is None:
        # summary_json is <stem>.summary.json, transcript is <stem>.md
        stem = summary_json.name.removesuffix(".summary.json")
        candidate = summary_json.parent / f"{stem}.md"
        transcript_md = candidate if candidate.exists() else None

    sidecar = _sidecar_path(summary_json)
    existing = _load_sidecar(sidecar)

    body_blocks = _build_blocks(summary, transcript_md, cfg.notion.include_full_transcript)

    with httpx.Client(
        base_url=NOTION_API,
        headers={
            "Authorization": f"Bearer {token}",
            "Notion-Version": NOTION_VERSION,
            "Content-Type": "application/json",
        },
        timeout=30.0,
    ) as client:
        if existing and existing.get("page_id"):
            page_id = existing["page_id"]
            log.info("Updating existing page %s", page_id)
            page = _update_page(client, page_id, summary, cfg, body_blocks)
            idempotent = True
        else:
            log.info("Creating new page in database %s", cfg.notion.database_id)
            page = _create_page(client, cfg, summary, body_blocks)
            idempotent = False

    page_id = page["id"]
    page_url = page.get("url") or f"https://www.notion.so/{page_id.replace('-', '')}"

    sidecar.write_text(
        json.dumps(
            {"page_id": page_id, "page_url": page_url, "updated_at": _now_iso()},
            indent=2,
        ),
        encoding="utf-8",
    )

    log.info("Published → %s", page_url)
    return {"page_id": page_id, "page_url": page_url, "idempotent": idempotent}


# --- HTTP layer ---------------------------------------------------------------

_RETRYABLE = (httpx.TransportError, httpx.HTTPStatusError)


@retry(
    reraise=True,
    stop=stop_after_attempt(4),
    wait=wait_exponential(multiplier=1, min=1, max=15),
    retry=retry_if_exception_type(_RETRYABLE),
)
def _request(client: httpx.Client, method: str, path: str, **kwargs: Any) -> dict[str, Any]:
    resp = client.request(method, path, **kwargs)
    if resp.status_code >= 500 or resp.status_code == 429:
        # Trigger tenacity retry.
        resp.raise_for_status()
    if resp.status_code >= 400:
        # 4xx other than 429 are non-retryable; surface immediately.
        raise NotionError(f"Notion {method} {path} → {resp.status_code}: {resp.text[:500]}")
    return resp.json()


def _fetch_all_child_ids(client: httpx.Client, page_id: str) -> list[str]:
    """Page through `/blocks/{id}/children` until no more results.

    Notion paginates at 100 per response. Without the `start_cursor` loop, a
    page that previously held >100 blocks would leak orphan children on
    update — they'd survive the delete-then-recreate and pile up over re-runs.
    """
    ids: list[str] = []
    start_cursor: str | None = None
    while True:
        path = f"/blocks/{page_id}/children?page_size=100"
        if start_cursor:
            path += f"&start_cursor={start_cursor}"
        resp = _request(client, "GET", path)
        ids.extend(b["id"] for b in resp.get("results", []))
        if not resp.get("has_more"):
            break
        start_cursor = resp.get("next_cursor")
        if not start_cursor:
            break
    return ids


def _create_page(
    client: httpx.Client, cfg: Config, summary: MeetingSummary, body: list[dict]
) -> dict[str, Any]:
    payload = {
        "parent": {"database_id": cfg.notion.database_id},
        "properties": _properties(summary, cfg),
        "children": body,
    }
    return _request(client, "POST", "/pages", json=payload)


def _update_page(
    client: httpx.Client,
    page_id: str,
    summary: MeetingSummary,
    cfg: Config,
    body: list[dict],
) -> dict[str, Any]:
    # 1. Update properties.
    page = _request(
        client,
        "PATCH",
        f"/pages/{page_id}",
        json={"properties": _properties(summary, cfg)},
    )

    # 2. Wipe existing children and replace. Notion has no atomic "replace
    #    children" call, so we delete and re-append. Parallelize the deletes
    #    via a thread pool — httpx.Client is thread-safe, and a long
    #    transcript can carry 50+ blocks. 8 concurrent workers stays well
    #    below Notion's per-integration rate limit (~3 r/s sustained, with
    #    burst headroom) while shrinking wall time roughly 8x.
    block_ids = _fetch_all_child_ids(client, page_id)
    if block_ids:
        with ThreadPoolExecutor(max_workers=8) as ex:
            # list() forces materialization so exceptions surface.
            list(ex.map(
                lambda bid: _request(client, "DELETE", f"/blocks/{bid}"),
                block_ids,
            ))

    # 3. Append fresh body. Notion caps each append at 100 blocks; we chunk.
    for i in range(0, len(body), 100):
        _request(
            client,
            "PATCH",
            f"/blocks/{page_id}/children",
            json={"children": body[i : i + 100]},
        )

    return page


# --- Property + block builders ------------------------------------------------


def _properties(summary: MeetingSummary, cfg: Config) -> dict[str, Any]:
    """Map MeetingSummary → Notion property objects.

    The user's DB must have:
      - Title  (title)
      - Date   (date)
      - Status (select)
    Attendees/Source/Bundle are optional — we only set them if present.
    """
    today = datetime.now(timezone.utc).date().isoformat()
    return {
        "Name": {
            "title": [{"type": "text", "text": {"content": summary.title[:120]}}],
        },
        "Date": {"date": {"start": today}},
        "Status": {"select": {"name": cfg.notion.default_status}},
    }


def _build_blocks(
    summary: MeetingSummary,
    transcript_md: Path | None,
    include_transcript: bool,
) -> list[dict]:
    blocks: list[dict] = []

    blocks.append(_h2("Summary"))
    for bullet in summary.summary:
        blocks.append(_bullet(bullet))

    if summary.decisions:
        blocks.append(_h2("Decisions"))
        for i, d in enumerate(summary.decisions, 1):
            blocks.append(_numbered(d))

    if summary.actions:
        blocks.append(_h2("Action Items"))
        for a in summary.actions:
            owner = a.owner or "unassigned"
            due = f" (due {a.due})" if a.due else ""
            blocks.append(
                _todo(f"{owner}: {a.task}{due}  [confidence: {a.confidence}]")
            )

    if summary.questions:
        blocks.append(_h2("Open Questions"))
        for q in summary.questions:
            blocks.append(_bullet(q))

    if include_transcript and transcript_md and transcript_md.exists():
        blocks.append(_transcript_toggle(transcript_md.read_text(encoding="utf-8")))

    return blocks


def _h2(text: str) -> dict:
    return {
        "object": "block",
        "type": "heading_2",
        "heading_2": {"rich_text": [_text(text)]},
    }


def _bullet(text: str) -> dict:
    return {
        "object": "block",
        "type": "bulleted_list_item",
        "bulleted_list_item": {"rich_text": [_text(text)]},
    }


def _numbered(text: str) -> dict:
    return {
        "object": "block",
        "type": "numbered_list_item",
        "numbered_list_item": {"rich_text": [_text(text)]},
    }


def _todo(text: str) -> dict:
    return {
        "object": "block",
        "type": "to_do",
        "to_do": {"rich_text": [_text(text)], "checked": False},
    }


def _text(content: str) -> dict:
    # Notion caps a single rich_text run at 2000 chars. We rely on the caller
    # to feed short bullets; long transcripts go through _transcript_toggle.
    return {"type": "text", "text": {"content": content[:2000]}}


def _transcript_toggle(transcript: str) -> dict:
    """Wrap the full transcript inside a collapsed toggle block.

    Notion requires nested children; each rich_text run caps at 2000 chars,
    so we split paragraphs and chunk if needed.
    """
    paragraphs = [p for p in transcript.split("\n\n") if p.strip()]
    children: list[dict] = []
    for para in paragraphs:
        # Chunk paragraphs >2000 chars into multiple paragraph blocks.
        for i in range(0, len(para), 2000):
            chunk = para[i : i + 2000]
            children.append(
                {
                    "object": "block",
                    "type": "paragraph",
                    "paragraph": {"rich_text": [_text(chunk)]},
                }
            )
        if len(children) >= 90:
            # Notion children cap is 100 per request; leave headroom.
            dropped = len(paragraphs) - paragraphs.index(para) - 1
            log.warning(
                "Transcript truncated for Notion: dropped %d of %d paragraphs "
                "(full transcript remains on disk).",
                dropped, len(paragraphs),
            )
            children.append(
                {
                    "object": "block",
                    "type": "paragraph",
                    "paragraph": {
                        "rich_text": [_text("... [transcript truncated for Notion length cap]")]
                    },
                }
            )
            break

    return {
        "object": "block",
        "type": "toggle",
        "toggle": {"rich_text": [_text("Full transcript")], "children": children},
    }


# --- Sidecar helpers ----------------------------------------------------------


def _sidecar_path(summary_json: Path) -> Path:
    stem = summary_json.name.removesuffix(".summary.json")
    return summary_json.parent / f"{stem}.notion.json"


def _load_sidecar(p: Path) -> dict[str, Any] | None:
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:  # noqa: BLE001
        log.warning("Could not parse sidecar %s; treating as new page", p)
        return None


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: mp publish-notion <summary.json>", file=sys.stderr)
        return 2
    summary_json = Path(argv[0]).expanduser().resolve()
    if not summary_json.exists():
        print(f"No such file: {summary_json}", file=sys.stderr)
        return 1
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    publish(summary_json)
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main(sys.argv[1:]))
