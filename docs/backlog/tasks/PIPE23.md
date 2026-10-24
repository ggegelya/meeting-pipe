# PIPE23: a Notion create that fails after Notion committed it duplicates the page on retry, a page deleted in Notion breaks every republish, and each republish resets Date and Status

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) P1, [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) UX-12 and PP-13). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

All in `pipeline/src/mp/publish_notion.py`, re-read on 2026-10-24.

**Idempotent on the client side only.** `NotionRestPublisher.upsert` decides create versus update from one thing, `<stem>.notion.json`: `if existing and existing.get("page_id")` updates, otherwise `_create_page` runs. `_create_page` deliberately calls `_request_once` because "Notion's edge has been observed to return 502 AFTER the backend committed the write" (the duplicate-page bug of 2026-05-11). That stops an automatic retry from duplicating, but the sidecar is written only after a successful response, so when the POST fails after the commit there is no sidecar, and the user's **Retry publishing** takes the create branch again and makes a second page. The docstring of `_request_once` already concedes the outcome: "the user sees an orphan page in Notion and deletes it manually". Nothing records which database row belongs to which meeting, so there is no natural key to look up.

**A page deleted in Notion is a dead end.** When the sidecar names a page the user has since deleted, `_update_page`'s first call, `PATCH /pages/{page_id}`, gets a 4xx and `_do_request` raises `NotionError`. Nothing clears the sidecar, so every later publish and retry of that meeting fails the same way until someone deletes `<stem>.notion.json` by hand.

**Republish rewrites user-owned columns.** `_properties` always writes `"Date": {"date": {"start": today}}`, where `today` is the publish moment's UTC date rather than the meeting's, and `"Status": {"select": {"name": cfg.notion.default_status}}` (`"Captured"` by default). Both go out on create and on every update, so a regenerate or retry resets a Status the user moved forward in Notion and stamps the publish day over the meeting day (go-live UX-12).

**The check verifies reachability, not the schema.** `doctor.check_notion` and the onboarding **Verify connection** (`NotionDatabaseList.verifyDatabase`) both pass on any `200` from `GET /databases/{id}`. `_properties` requires `Name` (title), `Date` (date) and `Status` (select), so a database missing one passes both checks and then fails every publish.

**Non-atomic sidecar.** `upsert` ends in `sidecar_path.write_text(...)`, not `storage.atomic_write_text`, so a crash mid-write leaves a sidecar `_load_sidecar` reads as absent ("treating as new page"), which is the duplicate path again.

**The API version is pinned three times in two trees** (go-live PP-13): `endpoints.NOTION_API_VERSION = "2022-06-28"` and two literal `req.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")` calls in `daemon/Sources/MeetingPipe/NotionDatabaseList.swift`.

## Scope

1. **A natural key.** When the probed schema (`_probe_db_properties`) defines a `Meeting ID` rich-text property, `_optional_properties` writes the stem into it, and before any create `upsert` queries the database for that stem and adopts a single match through the update path. Without the property: write a `pending_create_at` marker to the sidecar (atomically) before the POST; a later publish that finds the marker queries for pages with the same `Name` created at or after it, adopts exactly one match, and on several fails with a message naming them rather than creating another. The sink still never edits the database schema.
2. **Gone pages.** Before updating, `GET /pages/{page_id}`; on a 404 or `archived: true`, clear the sidecar, log it, and take the create path (which step 1 now makes safe).
3. **User-owned columns.** Create writes `Date` from the meeting's own date (the stem's `YYYYMMDD`, local) and `Status` from `default_status`. Update writes neither.
4. **Atomic sidecar** through `storage.atomic_write_text`.
5. **Schema check.** `mp doctor` and the onboarding verify both report a missing or mistyped `Name`, `Date` or `Status`, naming the property, from the same `GET /databases/{id}` response they already fetch.
6. **One version per tree, fenced.** The two Swift literals become one `Endpoints` constant, and a parity test (the CI3 pattern) fails when it differs from `mp.endpoints.NOTION_API_VERSION`.

## Explicitly not / out of scope

- Bumping the Notion API version. This only makes a bump one edit per tree with a fence.
- Whether the daemon should call Notion at all (the picker and verify use `URLSession` despite the "no outbound HTTP from the daemon" rule): HYG10 carries that owner call.
- Auto-creating `Meeting ID` in the user's database. The sink stays read-only on schema; SETUP documents the property as optional.
- The other sinks, which are file-based and idempotent by path.

## Acceptance

- New tests in `test_publish_notion.py` over a mock transport: a POST that answers 502 after recording the page, then a retry, ends with one page and a sidecar naming it, both with `Meeting ID` present and through the pending-marker fallback; two fallback matches fail with both page ids in the error; a sidecar naming a 404 or archived page publishes a new page and rewrites the sidecar; an update body carries no `Date` and no `Status`; a create's `Date` is the stem's date; the sidecar is written through the atomic helper.
- Doctor and onboarding tests: a database lacking `Date` is reported by name. The Swift/Python version parity test passes and fails on a planted mismatch (tried and reverted).
- `docs/SETUP.md` Step 6 lists the optional `Meeting ID` property in the same commit (the root `CLAUDE.md` setup contract).
- `cd pipeline && uv run --extra dev ruff check src tests`, `uv run --extra dev --extra mcp pyright`, `uv run --extra dev pytest -q`, and `cd daemon && swift test` green, with the new test count in the commit body.
