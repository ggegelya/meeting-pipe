# PIPE33: The Python side of the meeting-file contract has no owner: the stem is derived four ways and transcripts and segments travel as anonymous dicts

Band origin: filed 2026-10-25 from the 2026-10-25 code-quality audit band ([code-quality audit](../../audits/2026-10-25-code-quality-audit.md) PIPE33, finders PY4 and PY5). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

[ARCH10](./ARCH10.md) (filed 2026-10-24) gives the Swift side of the per-meeting file contract an owner, `MeetingFiles` in `MeetingPipeCore`, with a suffix list pinned against "a golden list shared with `pipeline/tests`". The Python side has no counterpart. Counted in `pipeline/src/mp` on 2026-10-25:

**The stem is derived by four rules.**

1. First dot, mirroring the daemon's `MeetingStore.stem(of:)`: `name.split(".", 1)[0]` at 9 sites (`actions.discover`, `digest`, `markers`, `prep`, `summarize._prior_meeting_context` twice, `visibility.library_stems` twice, `workflow.read_meta`).
2. `Path.stem`, which strips only the last suffix: 32 lines in 15 modules (`wav.stem`, `transcript_md.stem`, `path.stem`, ...). Correct for `<stem>.wav` and `<stem>.md`, wrong for anything with two suffixes: `Path("20261001-100000.summary.md").stem` is `20261001-100000.summary`.
3. Strip one known suffix: `removesuffix(".summary.json")` at 6 sites in `publish_cmd`, `publish_notion` and `publish_router`, `removesuffix(".notion.json")` in `publish_notion._load_meta_beside`, and `path.name[: -len(".run.json")]` in `train_adapter`.
4. Bespoke helpers: `markdown.deeplink_stem` (`Path.stem`, then strips a trailing `.summary`) and `corrections._stem_from_transcript` (strips `.md` only, so a `<stem>.summary.md` input yields `<stem>.summary`).

The rules agree on today's `YYYYMMDD-HHMMSS` stems with one suffix and disagree on the rest, and there is no single place a reader can check which one a new call site should use.

**Sibling paths are spelled by hand.** `.summary.json` appears on 39 lines in 18 modules, 21 of them string literals in 12 modules; `.meta.json` is built from a literal on 8 lines. There is no Python list of the suffixes a meeting owns.

**The transcript pair is an anonymous dict.** `orchestrate.finalize_streamed_transcript` and `finalize.finalize` return `dict[str, Path]`, and `t: dict[str, Path]` is threaded through `apply_glossary`, `_skip_result`, `_check_no_speech`, `_check_suspect_transcript`, `_check_byo`, `_check_too_long` and `_check_apple_handoff`, read as `t["md"]` (17 sites) and `t["json"]` (8). A typo in a key is a runtime `KeyError`.

**Segments are untyped.** `segments: list[dict]` appears on 26 lines in 11 modules, 12 of them function signatures, and `seg.get("speaker")` / `seg["speaker"]` is read 25 times in 6 modules, defensively in some places and by subscript in others. The writer's shape is Swift's `SidecarSegment` (`start`, `end`, `text`, `words`, `speaker`, all non-optional), with `TranscriptSidecar` documented as "byte-shape interchangeable with pipeline/src/mp/transcribe.py output".

Re-checked at filing: the audit's counts (28 `.summary.json` lines in 20 files, 26 signatures, 39 speaker reads) did not reproduce; the figures above are the 2026-10-25 recount. ARCH10's scope types `meta.json` and `summary.json` and adds the suffix list, but does not decide the transcript segment shape; the only typed writer of it is `SidecarSegment`.

## Scope

1. **`mp/meeting_files.py`**, a leaf module with no `mp` imports:
   - `stem_of(path: Path | str) -> str`, the first-dot rule, docstring naming `MeetingStore.stem(of:)` as its Swift twin.
   - Named suffix constants and `path(root: Path, stem: str, kind: str) -> Path`, plus `SUFFIXES`, the list of every suffix the pipeline writes or reads.
   - `SUFFIXES` is pinned against the golden suffix list ARCH10's acceptance names, in `daemon/Tests/MeetingPipeTests/Fixtures/`. Whichever of ARCH10 and PIPE33 lands first creates that fixture and its row in CONVENTIONS' "Cross-tree golden fixtures" table; the second adds its own side's test against it.
2. **Migrate** rules 1, 3 and 4 to `stem_of` (keep `deeplink_stem` as a wrapper for its `None` handling), and every `.summary.json` and `.meta.json` string-literal site to `meeting_files.path`. Rule 2 sites on single-suffix files (`wav.stem` of `<stem>.wav`) move only as they are touched.
3. **A fence** in `pipeline/tests` that fails on a new `".summary.json"` or `".meta.json"` string literal, or a new `.split(".", 1)[0]`, under `src/mp` outside `meeting_files.py`, by AST walk over string constants with docstrings skipped, so a prose mention does not count.
4. **`TranscriptFiles(NamedTuple)`** with `json` and `md`, returned by `finalize_streamed_transcript` and `finalize.finalize` and taken by the seven `orchestrate` helpers in place of `t: dict[str, Path]`.
5. **`Segment(TypedDict)`, after ARCH10 lands.** This leg starts only once ARCH10 has shipped, and types the shape that ARCH10 leaves the Swift writer with: from `SidecarSegment` as it stands then, `speaker` required unless ARCH10 made it optional. It replaces `list[dict]` in the 12 signatures, with no change to how a missing key is handled at each read (that is PIPE29's and the observability audit's ground). If ARCH10 is still open when legs 1 to 4 are done, ship them and leave this leg's progress note in the spec.

## Explicitly not / out of scope

- The Swift side (`MeetingFiles`, `MeetingMeta`, `SummaryDocument`, the job result envelope): ARCH10.
- Typing `meta.json` and `summary.json` dicts in Python. `MeetingSummary` already parses the summary; a meta `TypedDict` follows ARCH10's `MeetingMeta` the same way as leg 5 and is not filed here.
- Safe reading of these files: PIPE29. Atomic writing: PIPE30.
- Giving `run_all` injectable collaborators: T6. Splitting `summarize.py`: PIPE21. Dead-code and duplication sweeps: HYG16.
- STOR7 (deleting a meeting leaves derived files) will want `SUFFIXES`; it is not done here.

## Acceptance

- `test_meeting_files.py`: `stem_of` returns the stem for each of `<stem>.wav`, `.md`, `.summary.md`, `.summary.json`, `.summary.candidate.json`, `.READY_FOR_MANUAL.md` and a bare stem; `path` round-trips through `stem_of` for every entry in `SUFFIXES`; `SUFFIXES` equals the golden fixture's list.
- `test_corrections.py`: a correction record carrying only `transcript_path` still resolves to the same stem once `_stem_from_transcript` is replaced, for both a `<stem>.md` and a `<stem>.summary.md` path (the second resolves to `<stem>.summary` on `main`).
- The fence passes on the migrated tree and fails on a planted `f"{stem}.summary.json"` (tried and reverted, said in the commit body).
- pyright reports no new errors with `TranscriptFiles` in place, and `test_orchestrate.py` passes unchanged in behaviour.
- `bash scripts/ci-local.sh pipeline` green (and `daemon` if this task creates the shared fixture), with the number of new tests in the commit body.
