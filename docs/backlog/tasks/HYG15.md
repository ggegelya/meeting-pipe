# HYG15: The never-NSError(domain:) rule has twelve live violations outside the PipelineDriver stubs, and no fence

Band origin: filed 2026-10-25 from the 2026-10-25 code-quality audit band ([code-quality audit](../../audits/2026-10-25-code-quality-audit.md) CV3). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Re-checked at filing on 2026-10-25: the count of twelve holds, but FluidAudioRunner's four are narrower than a bare violation, since each is the `underlying:` payload of an already-named `TranscriptionError.audioReadFailed(url, underlying:)`, so a caller can branch on the outer case today and only the inner detail is hand-rolled.

`CONVENTIONS.md` "Error propagation" says: "Never `NSError(domain:code:userInfo:)`. A hand-rolled domain string plus `code: 1` carries no meaning a caller can branch on". ARCH4 (shipped 2026-07-10, archived in [q6-final.md](../q6-final.md)) wrote that rule after replacing eleven of them in `MeetingLibraryService` with `MeetingLibraryService.LibraryError`, which is the precedent shape: one nested `enum X: Error, LocalizedError` per subsystem, `errorDescription` returning the old message unchanged. Nothing enforces the rule. A multi-line-aware search of `daemon/Sources` (`NSError\(\s*domain:`, comments excluded) finds 28 constructions in five files:

- **16 in `extension PipelineDriver`** (`PipelineLauncher.swift`), every one `domain: "PipelineDriver", code: 1`. These are the protocol's default stubs and belong to A7, the driver leg of [ARCH5](./ARCH5.md)'s 2026-10-24 amendment, which removes the defaults so drift is a compile error.
- **4 more in `PipelineLauncher`**: `ask` (`domain: "mp ask", code: 1` for an answer that carries its own `error`, `code: 2` for "ask produced no readable result"), `restorePreview` (`"mp restore", code: 2`, "restore --dry-run produced no readable plan") and `actionClusters` (`"mp actions", code: 2`, "actions --cluster produced no readable result").
- **2 in `LibraryListView`**: the `onRetry` and `onExport` closures fall back to `.failure(NSError(domain: "LibraryListView", code: 1))` when the weak `libraryModel` is gone. These carry no `userInfo`, so a user would read Foundation's generic "The operation couldn't be completed. (LibraryListView error 1.)".
- **2 in `NotionDatabaseList`**: `refresh`'s fetch throws `domain: "NotionDatabaseList", code: http.statusCode`, and `verifyDatabase`'s local `fail(_:_:)` helper builds one for five throw points (invalid id, no HTTP response, 404, rejected token, other status), the code being `-1` or the status.
- **4 in `FluidAudioRunner`**: `domain: "FluidAudioRunner"`, codes 1 to 4, for an input-buffer allocation failure, "resampler unavailable", and the resampler's input and output allocations.

No caller branches on any of these domains or codes, in `Sources` or `Tests` (searched 2026-10-25), so the change is type-only and every message stays byte-identical. The doc comment on `MeetingLibraryService.LibraryError` quotes the old `NSError(domain: "MeetingLibraryService", ...)` form, which is why a fence must skip comments.

## Scope

One commit per file group, then the fence:

1. `PipelineLauncher`: a nested `enum ResultError: Error, LocalizedError` with `answerReported(String)` (the `ask` code-1 path) and `unreadableResult(String)` (the three "produced no readable" paths), descriptions unchanged. `askFailure` and `isCancellation` are untouched; `LaunchError` is not widened, since it describes the process, not its output file.
2. `LibraryListView`: one new `MeetingLibraryService.LibraryError` case for "the Library closed before this ran", with a real sentence, used by both closures.
3. `NotionDatabaseList`: a nested `enum NotionError: Error, LocalizedError` with `invalidDatabaseID`, `noResponse`, `databaseNotFound`, `tokenRejected(status:)` and `http(status:body:)`; `fail` keeps its `notion_verify_failed` event, its attributes unchanged.
4. `FluidAudioRunner`: a nested `enum BufferFailure: Error, LocalizedError` with four cases, passed as `underlying:`; `TranscriptionError` is unchanged.
5. **The fence**, in `scripts/truth_fences.py`. [HYG10](./HYG10.md) adds a `sources` check there for `@unchecked Sendable`, `URLSession` and raw `Process()` allowlists; this joins it as a fourth allowlist. If HYG10 has not landed, create the `sources` check with this one list and run it from `both`; whichever lands second merges into one check. Shape: `NSERROR_ALLOWLIST: dict[tuple[str, str], tuple[int, str]]` keyed by file and domain string, seeded with exactly `("daemon/Sources/MeetingPipe/PipelineLauncher.swift", "PipelineDriver"): (16, "A7 in ARCH5 removes the PipelineDriver default stubs")`. The match is `NSError\(\s*domain:` across line breaks over `daemon/Sources`, with `//` and `/* */` comments stripped. Any unlisted construction fails; a listed count that moves in either direction fails, so a seventeenth stub fails and A7 must delete the entry when it lands (the stale-entry contract `CLAUDE_ALLOWLIST` uses). The `CONVENTIONS.md` rule gains one clause naming the fence.

## Explicitly not / out of scope

- The 16 `PipelineDriver` stubs: A7 in [ARCH5](./ARCH5.md). This task allowlists them and does not touch the protocol.
- Whether the Notion database picker stays in the daemon: [HYG10](./HYG10.md)'s owner call. If the picker moves behind `mp`, item 3 disappears with it; do not move it here.
- `try?` swallowing, `except Exception` and the rest of the error-handling surface: handed to the parallel observability and error-handling audit (2026-10-25).
- `NSError` in `daemon/Tests` (fixtures may construct one) and `as NSError` casts of system errors, which read a domain rather than inventing one.
- The `@unchecked Sendable`, `URLSession` and `Process()` allowlists: HYG10.

## Acceptance

- A pytest beside [`test_link_fence.py`](../../../pipeline/tests/test_link_fence.py), loading the script by path the same way: a new single-line and a new multi-line `NSError(domain:` in a scratch Swift tree each fail; one inside a `///` comment does not; the seeded 16 pass; a seventeenth `"PipelineDriver"` construction fails; a listed entry whose file holds none fails as stale.
- Swift: per migrated type, a test that each case's `errorDescription` equals the string it replaced, and for `NotionDatabaseList.verifyDatabase` a stubbed 404 response throws `.databaseNotFound` (beside the existing `NotionDatabaseListTests`).
- `python3 scripts/truth_fences.py` green with only the A7 entry listed; `cd daemon && swift build` and `swift test` green; `bash scripts/ci-local.sh all` green; new test counts per tree in the commit bodies.
