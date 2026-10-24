# ARCH13: 200 of the daemon's 257 Swift files sit flat in Sources/MeetingPipe, so a doc table stands in for folder structure

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) A9). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Counted on 2026-10-24: `daemon/Sources/MeetingPipe` holds 257 `.swift` files, and 200 of them are at the top level. The eleven subfolders that exist hold the other 57 (`Preferences/` 14, `Design/` 12, `Onboarding/` 6, `Automation/` 5, `Tutorial/` 5, `Coordination/` 4, `Transcription/` 4, `CLI/` 2, `Library/` 2, `Summarization/` 2, `Util/` 1). The folders that exist are not used consistently: `Library/` holds `MeetingLibraryService.swift` and `MeetingSummary.swift` while ten `Library*.swift` files (`LibraryWindow`, `LibraryListView`, `LibraryChrome`, `LibrarySidebar`, ...) sit at the root, beside 21 `Meeting*` and 12 `Workflow*` files.

The stand-in for structure is ARCHITECTURE.md's "File index" table under "Daemon", one row per subsystem listing entry files by bare name. It is long, it drifts (DOC7 and DOC9 each spent a sweep on stale file docs), and a reader still cannot `ls` a subsystem.

The SwiftPM `MeetingPipe` target is declared with `path: "Sources/MeetingPipe"` and `resources: [.process("Resources")]`, and SwiftPM compiles every `.swift` file under the path recursively, so a move changes nothing in `Package.swift`.

What does reference the current paths, and has to move in the same commit:

- 62 path literals in 25 test files under `daemon/Tests/MeetingPipeTests`, via the local `daemonSource(...)` and `repoFile(...)` helpers (for example `daemonSource("Sources/MeetingPipe/TranscriptTab.swift")`). A wrong path throws and the test fails, so the suite finds every one. `CoordinatorWiringFenceTests` additionally `XCTSkip`s when `func start()` is not found, which is T7's to fix; it reads the file by path first, so a moved `Coordinator.swift` fails rather than skips.
- `scripts/truth_fences.py` reads `daemon/Sources/MeetingPipe/Config.swift` and `ConfigStore.swift` by path (CI5's config fence).
- `scripts/ci-local.sh` excludes `daemon/Sources/MeetingPipe/Design/Tokens.swift` and `Design/` from the token greps, and `scripts/install.sh` reads `Automation/MeetingPipeAppIntents.swift`; both folders stay where they are.
- 98 Markdown links into top-level daemon sources, in 19 tracked files (the q6 backlog index, `q4-final.md`, `q6-final.md`, 15 task specs, one spike doc). CI5's dead-link fence fails on every one that breaks.

## Scope

1. **One move-only commit.** `git mv` every top-level file into a feature folder, and change nothing else in any `.swift` file, so `git log --follow` and rename detection keep history. Target folders, extending the ones that exist rather than renaming them: `App/` (entry point, `AppDelegate`, single-instance guard, main menu, window activation), `Detection/`, `Recording/`, `Transcription/`, `Coordination/` (the spine: `Coordinator*`, `MeetingSessionController`, `SessionHost`), `Pipeline/` (launcher, job lane, failure sidecars), `Library/`, `Workflows/`, `Search/`, `Speakers/`, `Preferences/`, `Design/`, plus the existing `Automation/`, `CLI/`, `Onboarding/`, `Summarization/`, `Tutorial/`. A file that fits two folders goes where its main type's callers are; the commit body lists the judgement calls.
2. **Same commit, the references above:** the test path literals, the two `truth_fences.py` paths, and the 98 doc links (a scripted rewrite from the `git mv` list, then `python3 scripts/truth_fences.py links` to confirm zero dead links).
3. **Follow-up commit:** shrink ARCHITECTURE.md's daemon file index to one row per folder (folder, what it owns, one or two entry files), and drop rows that only restated file names.
4. Land it when no other session has an open worktree under `.claude/worktrees/`, since a move-only commit conflicts with any in-flight edit to a moved file. Rename detection carries most later rebases, but there is no reason to test that against live work.

## Explicitly not / out of scope

- No new SwiftPM targets or modules. Three targets is right (architecture review A10); `MeetingPipeCore` is the boundary that matters and is already a target.
- No renames of files or types, no access-control changes, no code edits in the move commit, so the review is "is every file in a sensible folder" and nothing else.
- Moving tests into matching subfolders of `Tests/MeetingPipeTests`. Worth doing later, not in this commit.
- Splitting the large files (ARCH7, ARCH8, ARCH5's view leg): those are code changes and land separately, before or after.
- DOC17's per-subsystem split of ARCHITECTURE.md as a whole; step 3 only shrinks the daemon file index, and DOC17 can build on it.

## Acceptance

- `find daemon/Sources/MeetingPipe -maxdepth 1 -name '*.swift' | wc -l` is under 10 (only files with no better home, each named in the commit body).
- `git show --stat` of the move commit shows only renames plus the test, `truth_fences.py` and `.md` edits; `git diff -M --diff-filter=R` reports every moved file at 100% similarity.
- `cd daemon && swift build` and `swift build -c release` green, `swift test` green with the same test count before and after the move (no test was lost to a broken path), `bash scripts/ci-local.sh` green, `python3 scripts/truth_fences.py` green.
- `bash scripts/test-app-relocation.sh` green, since it builds the staged app from the release products.
- The ARCHITECTURE.md daemon file index has one row per folder after step 3.
