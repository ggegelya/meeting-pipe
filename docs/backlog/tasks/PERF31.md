---
id: PERF31
title: Opening the Recent meetings submenu lists and mtime-sorts the whole recordings directory on the main thread
category: Performance
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). `RecentMeetingsMenuDelegate.menuNeedsUpdate` calls `MeetingLibraryService.recentCorrectableMeetings(limit: 10)`, which runs `contentsOfDirectory` over the whole of `raw/` and sorts every `.run.json` by mtime on main each time the submenu opens, in a folder that syncs to iCloud on the owner's machines; PERF24 left it on main by design. Scope: compute the list off main on the status menu's open with PERF24's cached-read pattern, show the cached list in the submenu, and repopulate it if the answer changes while open. [Spec](./PERF31.md)
---

# PERF31: Opening the Recent meetings submenu lists and mtime-sorts the whole recordings directory on the main thread

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: F207 in [2026-11-12-independent-audit.md](../../audits/2026-11-12-independent-audit.md) (performance, filed unverified by the audit). Re-verified at HEAD `3a2da4fc` on 2026-11-13: the claim holds.

**The path.** `StatusBarController.recentMeetingsMenuItem` gives the "Recent meetings…" submenu a `RecentMeetingsMenuDelegate`, whose comment says it "Populates the 'Recent meetings' submenu on open (re-scans the dir, paid per click not per rebuild)". Its `menuNeedsUpdate` calls `coordinator.recentCorrectableMeetings(limit: 10)`, a forwarder to `MeetingLibraryService.recentCorrectableMeetings`, which runs `fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])` over the recordings directory, filters `.run.json`, and sorts with a comparator that calls `resourceValues(forKeys: [.contentModificationDateKey])` on both sides of every comparison. AppKit calls `menuNeedsUpdate` on main and waits for it before drawing the submenu. The rows are only stems (`displayName: stem`), so the list needs nothing but names and mtimes.

**Why it matters here.** The recordings folder holds about seven files per meeting, and on the owner's machines it sits under `~/Documents`, which syncs to iCloud, where a directory listing can wait on the File Provider. [PERF24](./PERF24.md) (done) moved the same kind of listing off main for the status menu's failed count, with the reasoning in `MeetingLibraryService.failedMeetingCount(in:)`'s doc: "It lists the whole of `raw/`, about seven entries per meeting, so a year of meetings is thousands of entries in a folder that may sync to iCloud: never on the main thread, and not per menu rebuild."

Correction at filing: PERF24 did not miss this. Its Explicitly not lists "The Recent meetings submenu's listing in `RecentMeetingsMenuDelegate.menuNeedsUpdate`, paid only when that submenu opens, by design." This task revisits that call, because the cost is per hover rather than per state change but it is still a whole-folder listing on main, the same thing PERF24's own doc rules out. Also corrected, from the audit's suggested fix: caching from `MeetingStore`'s scan is not available, since only `LibraryWindow` calls `meetingStore.start()` and the watcher is suspended while the Library is hidden, so with the Library closed there is no fresh scan to read. And the listing lives in `MeetingLibraryService`, not a view or controller file, so [OBS7](./OBS7.md)'s Fence B over `contentsOfDirectory` in controller files would not catch it as written.

Not measured: no event brackets a submenu open, and the audit gives no latency.

## Scope

1. **Compute the list off main on the parent menu's open.** In `StatusBarController.refreshMenuBeforeDisplay`, beside `refreshFailedMeetingCount()`, start a refresh of the recent list on `countQueue` through an injected `@Sendable (URL) -> [(stem: String, displayName: String)]` provider (defaulting to a static, directory-taking form of `recentCorrectableMeetings`, as `failedMeetingCount(in:)` is). The result lands on main into a cached array; a changed result calls `repopulateIfOpen()` or rebuilds the open submenu in place. `primeCachedReads()` primes it at launch.
2. **The submenu reads only the cache.** `RecentMeetingsMenuDelegate.menuNeedsUpdate` builds its rows from the cached array and touches no disk. Its comment changes to say so.
3. **One listing per open, if it is cheap to share.** The failed count and the recent list each list `raw/`; the pickup may fold them into one off-main listing that yields both. Optional.
4. **Sort once.** Read each `.run.json`'s mtime once (the prefetched key) and sort by the stored value, not by `resourceValues` in the comparator.

## Explicitly not

- Showing meeting titles instead of stems in the submenu: a UX change, not this task.
- Moving the correction window's own load: `CorrectionWindow.present` is out of scope.
- A recordings-folder watcher for the status menu: the per-open refresh is enough, as PERF24 decided for the failed count.

## Acceptance

- `StatusBarController` tests in the PERF24 shape (driving the menu delegates directly): opening the status menu calls the injected recent-list provider off main, exactly once per open; the submenu's `menuNeedsUpdate` builds rows from the cached list and does not call the provider; a provider result that changes while the menu is open repopulates the submenu; an empty result renders the disabled "No recent meetings" row.
- A `MeetingLibraryServiceTests` case for the directory-taking form: newest-first by `.run.json` mtime, at most `limit`, stems with the `.run.json` suffix stripped.
- `cd daemon && swift build` and `swift test` green, N new tests named in the commit body; `bash scripts/ci-local.sh` green.
- Evidence line, not a gate: with a large library on the laptop, hovering Recent meetings shows rows with no visible hitch.
