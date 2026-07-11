"""Publish a MeetingSummary to a Notion database.

Idempotency strategy: after the first POST, we stash the returned `page_id`
in `<stem>.notion.json` next to the audio. On rerun, we PATCH the existing
page (properties + body block replacement) instead of creating a new one.

Body structure (P4.3 redesign, see `_build_blocks`):
1. Summary (single callout)
2. Decisions (numbered list, bold opener)
3. Action Items (to_do blocks)
4. Open Questions (collapsed toggle)
5. Full transcript (collapsed toggle, written only when notion.include_full_transcript is true)

The Name (title), Date, and Status properties are always written, so a
database needs only those three columns. Beyond them the sink probes the target
database schema once per publish and fills any optional property it recognises
by name and type (Workflow, Source, Attendees, Open actions), reading them from
the meeting's sidecars (PIPE5). Enrichment is fail-soft: a database that lacks a
property is skipped silently, a type mismatch is skipped with one log line, a
failed probe collapses back to the three base columns, and the sink never
creates or mutates database schema.
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

from . import entry
from .config import Config, require_env, zero_egress
from .endpoints import NOTION_API_BASE, NOTION_API_VERSION, notion_page_url
from .schemas import MeetingSummary
from .services import MeetingPublisher

log = logging.getLogger("mp.publish_notion")


class NotionError(RuntimeError):
    pass


class NotionRestPublisher:
    """Concrete `MeetingPublisher` that talks to api.notion.com directly.

    Owns the httpx client and the create-vs-update decision, but stays
    schema-thin: property mapping and block layout live in module-level
    helpers below so they can be unit-tested in isolation.
    """

    name = "notion"

    def __init__(self, *, token: str, cfg: Config) -> None:
        self._cfg = cfg
        self._headers = {
            "Authorization": f"Bearer {token}",
            "Notion-Version": NOTION_API_VERSION,
            "Content-Type": "application/json",
        }

    def upsert(
        self,
        *,
        summary: MeetingSummary,
        transcript_md: Path | None,
        sidecar_path: Path,
    ) -> dict[str, Any]:
        existing = _load_sidecar(sidecar_path)
        body_blocks = _build_blocks(
            summary, transcript_md, self._cfg.notion.include_full_transcript
        )

        with httpx.Client(
            base_url=NOTION_API_BASE,
            headers=self._headers,
            timeout=30.0,
        ) as client:
            # PIPE5: probe the target DB schema and load the meeting's meta sidecar
            # once, so `_properties` can fill the optional columns this database
            # actually defines. Both reads are fail-soft (empty on any failure), so
            # a bare Name/Date/Status database publishes byte-identically to before.
            db_props = _probe_db_properties(client, self._cfg.notion.database_id)
            meta = _load_meta_beside(sidecar_path)
            if existing and existing.get("page_id"):
                page_id = existing["page_id"]
                log.info("Updating existing page %s", page_id)
                page = _update_page(
                    client, page_id, summary, self._cfg, body_blocks,
                    meta=meta, db_props=db_props,
                )
                idempotent = True
            else:
                log.info("Creating new page in database %s", self._cfg.notion.database_id)
                page = _create_page(
                    client, self._cfg, summary, body_blocks,
                    meta=meta, db_props=db_props,
                )
                idempotent = False

        page_id = page["id"]
        page_url = page.get("url") or notion_page_url(page_id)

        sidecar_path.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "page_id": page_id,
                    "page_url": page_url,
                    "updated_at": _now_iso(),
                },
                indent=2,
            ),
            encoding="utf-8",
        )

        log.info("Published → %s", page_url)
        return {"page_id": page_id, "page_url": page_url, "idempotent": idempotent}


def apply_meeting_title(summary: MeetingSummary, summary_json: Path) -> MeetingSummary:
    """Prefer the meeting name the daemon extracted at recording-start time
    (Zoom topic, Calendar event behind a Meet link, Slack channel) over the
    LLM-derived title, so every sink shows the same title. Falls back to
    `summary.title` when `<stem>.meta.json` is absent or carries no title; older
    recordings stay unaffected. Shared by the legacy `publish()` path and the
    `publish_router.fanout` path so the two no longer diverge (PIPE2/AUD-15)."""
    meta = _load_meta_sidecar(summary_json)
    if meta:
        meeting_title = (meta.get("meeting_title") or "").strip()
        if meeting_title:
            return summary.model_copy(update={"title": meeting_title[:120]})
    return summary


def publish(
    summary_json: Path,
    cfg: Config | None = None,
    transcript_md: Path | None = None,
    *,
    publisher: MeetingPublisher | None = None,
) -> dict[str, Any]:
    """Publish the summary; return {page_id, page_url, idempotent: bool}.

    Pass a custom `publisher` to redirect output (e.g. local-only, test
    capture); defaults to `NotionRestPublisher`. Short-circuits under
    `config.zero_egress` before any publisher is instantiated, and arms the
    process-wide egress guard on the resolved config as the structural backstop.
    This entry point backs both `mp publish-notion` and `mp publish-from-paste`;
    the run-all / `mp publish` path goes through publish_router.fanout, whose
    `effective_sinks` drops the Notion sink under the same predicate (SEC2).
    """
    # `mp publish-notion <summary.json>` is an explicit "put this in Notion"
    # instruction, so the skip keys off `zero_egress` (SEC13) rather than off
    # `effective_sinks`: a user whose `output.sinks` omits notion still means it
    # when they name the subcommand. Both clamps now read the same predicate, so
    # the zero-egress invariant has exactly one owner (TECH-ARCH1).
    cfg = entry.prepare(cfg, summary_json)

    if zero_egress(cfg):
        log.info("regulated_mode/NDA active → skipping Notion publish")
        return {"page_id": None, "page_url": None, "regulated": cfg.modes.regulated_mode}

    if not cfg.notion.database_id:
        raise NotionError("notion.database_id is empty in config.toml")

    summary = MeetingSummary.model_validate_json(summary_json.read_text(encoding="utf-8"))

    # Default the transcript path to <stem>.md (rendered by run-all's finalize stage from the daemon's FluidAudio <stem>.json).
    if transcript_md is None:
        # summary_json is <stem>.summary.json, transcript is <stem>.md
        stem = summary_json.name.removesuffix(".summary.json")
        candidate = summary_json.parent / f"{stem}.md"
        transcript_md = candidate if candidate.exists() else None

    # Prefer the daemon-extracted meeting name over the LLM title, via the
    # shared helper so the fanout path applies it identically (PIPE2/AUD-15).
    summary = apply_meeting_title(summary, summary_json)

    sidecar = _sidecar_path(summary_json)

    if publisher is None:
        token = require_env("NOTION_TOKEN")
        publisher = NotionRestPublisher(token=token, cfg=cfg)

    return publisher.upsert(
        summary=summary,
        transcript_md=transcript_md,
        sidecar_path=sidecar,
    )


# --- HTTP layer ---------------------------------------------------------------

_RETRYABLE = (httpx.TransportError, httpx.HTTPStatusError)


def _do_request(client: httpx.Client, method: str, path: str, **kwargs: Any) -> dict[str, Any]:
    """One-shot HTTP call. Maps the response into either a NotionError
    (terminal 4xx) or an HTTPStatusError / TransportError (transient,
    safely retryable on idempotent operations). Callers wrap with
    `_request_retrying` only when the underlying HTTP verb tolerates
    a duplicate request."""
    resp = client.request(method, path, **kwargs)
    if resp.status_code >= 500 or resp.status_code == 429:
        # Surface as HTTPStatusError so the retry wrapper (when used)
        # can react to it. Non-idempotent callers do NOT wrap, and the
        # exception propagates to the caller as a hard fail.
        resp.raise_for_status()
    if resp.status_code >= 400:
        # 4xx other than 429 are non-retryable; surface immediately.
        raise NotionError(f"Notion {method} {path} → {resp.status_code}: {resp.text[:500]}")
    return resp.json()


@retry(
    reraise=True,
    stop=stop_after_attempt(4),
    wait=wait_exponential(multiplier=1, min=1, max=15),
    retry=retry_if_exception_type(_RETRYABLE),
)
def _request_retrying(client: httpx.Client, method: str, path: str, **kwargs: Any) -> dict[str, Any]:
    """Retrying wrapper for IDEMPOTENT operations (GET, DELETE, PATCH
    to a specific resource). Safe to repeat: the server either sees a
    new request and applies it idempotently, or the duplicate is a
    no-op (DELETE of already-deleted, PATCH with same property values).
    """
    return _do_request(client, method, path, **kwargs)


def _request_once(client: httpx.Client, method: str, path: str, **kwargs: Any) -> dict[str, Any]:
    """Non-retrying wrapper for NON-IDEMPOTENT operations:

      - POST /v1/pages       → creates a new page; a retry after a
                               502 makes a DUPLICATE.
      - PATCH /v1/blocks/{id}/children → APPENDS blocks; a retry
                               doubles the body content.

    Failing loudly is strictly better than silently duplicating. The
    user can re-run after a transient blip; if the original POST
    actually committed (502 after server-side write), the user sees
    an orphan page in Notion and deletes it manually. We'd rather
    surface that to a human than let the pipeline create twins.

    Pre-2026-05-11 behaviour wrapped this with the same retry as
    idempotent ops, which is the root cause of the duplicate-Notion-
    page bug observed against the 10:30 standup recording.
    """
    return _do_request(client, method, path, **kwargs)


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
        resp = _request_retrying(client, "GET", path)
        ids.extend(b["id"] for b in resp.get("results", []))
        if not resp.get("has_more"):
            break
        start_cursor = resp.get("next_cursor")
        if not start_cursor:
            break
    return ids


def _create_page(
    client: httpx.Client,
    cfg: Config,
    summary: MeetingSummary,
    body: list[dict],
    *,
    meta: dict[str, Any] | None = None,
    db_props: dict[str, str] | None = None,
) -> dict[str, Any]:
    payload = {
        "parent": {"database_id": cfg.notion.database_id},
        "properties": _properties(summary, cfg, meta=meta, db_props=db_props),
        "children": body,
    }
    # POST /pages is non-idempotent: Notion's edge has been observed to
    # return 502 AFTER the backend committed the write. A retry then
    # creates a second page (duplicate-Notion-page bug, 2026-05-11).
    return _request_once(client, "POST", "/pages", json=payload)


def _update_page(
    client: httpx.Client,
    page_id: str,
    summary: MeetingSummary,
    cfg: Config,
    body: list[dict],
    *,
    meta: dict[str, Any] | None = None,
    db_props: dict[str, str] | None = None,
) -> dict[str, Any]:
    # 1. Update properties. PATCH on a specific page is idempotent
    #    (same body applied twice is a no-op), safe to retry.
    page = _request_retrying(
        client,
        "PATCH",
        f"/pages/{page_id}",
        json={"properties": _properties(summary, cfg, meta=meta, db_props=db_props)},
    )

    # 2. Wipe existing children and replace. Notion has no atomic "replace
    #    children" call, so we delete and re-append. Parallelize the deletes
    #    via a thread pool: httpx.Client is thread-safe, and a long
    #    transcript can carry 50+ blocks. 8 concurrent workers stays well
    #    below Notion's per-integration rate limit (~3 r/s sustained, with
    #    burst headroom) while shrinking wall time roughly 8x. DELETE is
    #    idempotent (already-deleted returns 404, surfaced as NotionError).
    block_ids = _fetch_all_child_ids(client, page_id)
    if block_ids:
        with ThreadPoolExecutor(max_workers=8) as ex:
            # list() forces materialization so exceptions surface.
            list(ex.map(
                lambda bid: _request_retrying(client, "DELETE", f"/blocks/{bid}"),
                block_ids,
            ))

    # 3. Append fresh body. Notion caps each append at 100 blocks; we chunk.
    #    PATCH /blocks/{id}/children is APPEND, not replace; retrying after
    #    a 502 doubles the body content. Use the non-retrying helper.
    for i in range(0, len(body), 100):
        _request_once(
            client,
            "PATCH",
            f"/blocks/{page_id}/children",
            json={"children": body[i : i + 100]},
        )

    return page


# --- Property + block builders ------------------------------------------------


def _properties(
    summary: MeetingSummary,
    cfg: Config,
    *,
    meta: dict[str, Any] | None = None,
    db_props: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Map MeetingSummary → Notion property objects.

    The user's DB must have Name (title), Date (date), and Status (select); these
    three are always written. When `db_props` (the probed schema) and `meta` (the
    `<stem>.meta.json` sidecar) are supplied, any recognised optional property the
    database also defines is filled from the meeting's data (PIPE5); see
    `_optional_properties`. Without them (the default), only the three base
    columns are written, byte-identical to a pre-PIPE5 publish.
    """
    today = datetime.now(timezone.utc).date().isoformat()
    props: dict[str, Any] = {
        "Name": {
            "title": [{"type": "text", "text": {"content": summary.title[:120]}}],
        },
        "Date": {"date": {"start": today}},
        "Status": {"select": {"name": cfg.notion.default_status}},
    }
    props.update(_optional_properties(summary, meta or {}, db_props or {}))
    return props


def _probe_db_properties(client: httpx.Client, database_id: str) -> dict[str, str]:
    """Best-effort read of the target database's property schema (PIPE5).

    Returns ``{property_name: notion_type}`` so `_optional_properties` fills only
    the optional columns the database actually defines. Fail-soft: any failure
    (unreachable, 4xx, malformed body) yields ``{}``, which collapses enrichment
    back to the Name/Date/Status base set. This is a read; the sink never creates
    or mutates schema.
    """
    if not database_id:
        return {}
    try:
        resp = _request_retrying(client, "GET", f"/databases/{database_id}")
    except Exception as e:  # noqa: BLE001
        log.info("Notion schema probe failed (%s); writing base properties only", e)
        return {}
    props = resp.get("properties")
    if not isinstance(props, dict):
        return {}
    out: dict[str, str] = {}
    for name, spec in props.items():
        if isinstance(spec, dict) and isinstance(spec.get("type"), str):
            out[name] = spec["type"]
    return out


def _optional_properties(
    summary: MeetingSummary,
    meta: dict[str, Any],
    db_props: dict[str, str],
) -> dict[str, Any]:
    """Fill the optional Notion properties the target database defines (PIPE5).

    For each recognised property, write it only when the database carries a
    property of that exact name AND the expected Notion type. A property the
    database lacks is skipped silently; a name that exists with the wrong type is
    skipped with one log line. Empty select/multi-select values are skipped so a
    republish never wipes a hand-set field; ``Open actions`` writes its count
    (including 0), which is the filterable signal the property exists for.
    """
    if not db_props:
        return {}
    out: dict[str, Any] = {}

    def _fill(name: str, expected_type: str, value: Any) -> None:
        actual = db_props.get(name)
        if actual is None:
            return  # not defined on this database; skip silently
        if actual != expected_type:
            log.info(
                "Notion property %r is %s, expected %s for enrichment; skipping",
                name, actual, expected_type,
            )
            return
        if value is not None:
            out[name] = value

    workflow = _sanitize_option_name(meta.get("workflow_name"))
    _fill("Workflow", "select", {"select": {"name": workflow}} if workflow else None)

    source = _sanitize_option_name(meta.get("source_display_name"))
    _fill("Source", "select", {"select": {"name": source}} if source else None)

    attendees = [
        clean for a in summary.attendees if (clean := _sanitize_option_name(a))
    ][:25]
    _fill(
        "Attendees",
        "multi_select",
        {"multi_select": [{"name": a} for a in attendees]} if attendees else None,
    )

    open_actions = sum(1 for a in summary.actions if not a.resolved)
    _fill("Open actions", "number", {"number": open_actions})

    return out


def _sanitize_option_name(value: Any) -> str:
    """Coerce a value into a Notion select/multi-select option name.

    Notion rejects option names containing a comma, so commas become spaces; the
    name is trimmed and capped at Notion's practical length. Non-strings and
    blanks return ``""`` so the caller skips them.
    """
    if not isinstance(value, str):
        return ""
    return value.replace(",", " ").strip()[:100]


def _load_meta_beside(notion_sidecar: Path) -> dict[str, Any]:
    """Load the daemon's `<stem>.meta.json` sitting next to the notion sidecar,
    for property enrichment (PIPE5). Fail-soft: absent or malformed yields ``{}``.
    Derives the stem from the notion sidecar path so both the `publish()` and the
    `publish_router.fanout` call paths resolve the same meta file.
    """
    stem = notion_sidecar.name.removesuffix(".notion.json")
    data = _load_sidecar(notion_sidecar.parent / f"{stem}.meta.json")
    return data if isinstance(data, dict) else {}


def _build_blocks(
    summary: MeetingSummary,
    transcript_md: Path | None,
    include_transcript: bool,
) -> list[dict]:
    """Compose the Notion page body.

    Layout per Roadmap P4.3 ("looks deliberate, not algorithmic"):

      - Summary: a single info-callout block joining the bullets with
        line breaks. The previous bullet-list rendering felt like the
        page was "a list of lists".
      - Decisions: numbered list. First clause (text up to the first
        ':' or '.') rendered bold so each item has a clear opening.
      - Action items: to-do block with the owner styled as a coloured
        mention pill, due date inline, and a confidence chip whose
        color varies by level (high=blue, medium=default, low=gray).
        Real Notion @mentions require a user-ID lookup we do not have;
        the pill is the closest we can get without that round-trip.
      - Open questions: collapsed toggle so the page does not lead
        with what we don't know.
      - Transcript: collapsed toggle (unchanged).
    """
    blocks: list[dict] = []

    blocks.append(_h2("Summary"))
    blocks.append(_callout("\n".join(summary.summary), emoji="🎯"))

    if summary.decisions:
        blocks.append(_h2("Decisions"))
        for d in summary.decisions:
            blocks.append(_numbered_with_bold_opener(d))

    if summary.actions:
        blocks.append(_h2("Action Items"))
        for a in summary.actions:
            blocks.append(_action_block(
                task=a.task,
                owner=a.owner,
                due=a.due,
                confidence=a.confidence,
                resolved=a.resolved,
            ))

    if summary.questions:
        blocks.append(_h2("Open Questions"))
        blocks.append(_questions_toggle(summary.questions))

    # WF7: workflow-defined extra sections, after the standard ones and before
    # the transcript toggle. Skip an empty one so a bare heading never lands.
    for sec in summary.extra_sections:
        if not sec.content:
            continue
        blocks.append(_h2(sec.name))
        for item in sec.content:
            blocks.append(_bullet(item))

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


def _text(content: str, *, bold: bool = False, color: str = "default") -> dict:
    # Notion caps a single rich_text run at 2000 chars. We rely on the caller
    # to feed short bullets; long transcripts go through _transcript_toggle.
    block: dict = {"type": "text", "text": {"content": content[:2000]}}
    annotations: dict = {}
    if bold:
        annotations["bold"] = True
    if color != "default":
        annotations["color"] = color
    if annotations:
        block["annotations"] = annotations
    return block


# ---------- Block builders for the redesigned page (P4.3) -----------

def _callout(text: str, *, emoji: str = "💬") -> dict:
    return {
        "object": "block",
        "type": "callout",
        "callout": {
            "rich_text": [_text(text)],
            "icon": {"type": "emoji", "emoji": emoji},
            "color": "blue_background",
        },
    }


def _numbered_with_bold_opener(text: str) -> dict:
    """Bold the opening clause of a decision so each numbered item has
    a visible lede. Splits at the first ':' or '. ' (whichever comes
    first); the opener is whatever comes before, the rest is plain.
    Falls back to plain text when neither delimiter appears in the
    first 60 chars."""
    head, tail = _split_opening_clause(text)
    runs: list[dict] = [_text(head, bold=True)]
    if tail:
        runs.append(_text(tail))
    return {
        "object": "block",
        "type": "numbered_list_item",
        "numbered_list_item": {"rich_text": runs},
    }


def _split_opening_clause(text: str) -> tuple[str, str]:
    # Look for ':' first since it's the more emphatic split ("Ship: ...").
    # Cap at 60 to avoid bolding half a paragraph.
    cut_at = -1
    for i, ch in enumerate(text[:60]):
        if ch == ":":
            cut_at = i + 1
            break
    if cut_at == -1:
        for i in range(min(len(text) - 1, 60)):
            if text[i] == "." and text[i + 1] == " ":
                cut_at = i + 1
                break
    if cut_at <= 0:
        return text, ""
    return text[:cut_at], text[cut_at:]


_CONFIDENCE_COLOR = {"high": "blue", "medium": "default", "low": "gray"}


def _action_block(
    *,
    task: str,
    owner: str | None,
    due: str | None,
    confidence: str,
    resolved: bool = False,
) -> dict:
    runs: list[dict] = []
    # Owner mention pill: bold + colored. Real Notion @mentions need a
    # user-ID lookup we do not have without a separate config map.
    owner_label = f"@{owner}" if owner else "@unassigned"
    owner_color = "blue" if owner else "gray"
    runs.append(_text(owner_label, bold=True, color=owner_color))
    runs.append(_text(" "))
    runs.append(_text(task))
    if due:
        runs.append(_text(f"  ({due})", color="brown"))
    runs.append(_text("  "))
    chip_color = _CONFIDENCE_COLOR.get(confidence, "default")
    runs.append(_text(f"[{confidence}]", color=chip_color, bold=(confidence == "high")))
    # `checked` mirrors the resolved flag so a done action round-trips as a
    # ticked Notion to-do; an open one stays unchecked.
    return {
        "object": "block",
        "type": "to_do",
        "to_do": {"rich_text": runs, "checked": resolved},
    }


def _questions_toggle(questions: list[str]) -> dict:
    children = [_bullet(q) for q in questions]
    return {
        "object": "block",
        "type": "toggle",
        "toggle": {
            "rich_text": [_text(f"{len(questions)} unresolved")],
            "children": children,
        },
    }


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


def _meta_sidecar_path(summary_json: Path) -> Path:
    """Path to the daemon-produced metadata sidecar (meeting name, source app)."""
    stem = summary_json.name.removesuffix(".summary.json")
    return summary_json.parent / f"{stem}.meta.json"


def _load_meta_sidecar(summary_json: Path) -> dict[str, Any] | None:
    p = _meta_sidecar_path(summary_json)
    if not p.exists():
        return None
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else None
    except Exception:  # noqa: BLE001
        log.warning("Could not parse meta sidecar %s; ignoring", p)
        return None


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
