---
id: PERF30
title: Library search waits 200 ms plus an index lookup even for title, app and summary matches that need no index
category: Performance
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). PERF20's debounce took the FTS query off main, but `LibraryListView.recomputeDerived` substitutes the settled query for the typed one (`effective.query = settled.query`), so in-memory matches on title, app and summary text also wait for the 200 ms debounce and the lookup. Scope: apply the typed text to the in-memory corpus on every keystroke, pass FTS matches only when they were computed for the typed query, and merge transcript-depth rows when the lookup lands, as Quick Find already does. [Spec](./PERF30.md)
---

# PERF30: Library search waits 200 ms plus an index lookup even for title, app and summary matches that need no index

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Sources: P022 and P049 in [2026-11-13-responsiveness-audit.md](../../audits/2026-11-13-responsiveness-audit.md) (both low, head only, from code; the pack logs no Library key presses). Every code claim below was re-read at HEAD `3a2da4fc` on 2026-11-13.

**What PERF20 changed.** Before [PERF20](./PERF20.md) (done, commit `5e9db6e2`, 2026-11-12) every keystroke ran a bm25-ranked FTS query through `SearchIndex`'s `queue.sync` on main inside `recomputeDerived`. PERF20 replaced that with `FTSLookup`: `static let debounce: TimeInterval = 0.2`, the lookup on `FTSLookup.lookupQueue`, delivery on main, latest wins. The typed character still appears in the field at once (the `TextField` binds straight to `filter.query`).

**What still waits.** `LibraryListView.resolveSearch` writes `settled = SettledSearch(query: typed, matches: matches, ...)` only when the lookup delivers, and `recomputeDerived` builds the list from that: `var effective = filter; effective.query = settled.query`, then `MeetingFilterEngine.apply(effective, to: scoped, ftsMatches: settled.matches[settled.query])`. So for any query of two or more characters the list and its match count stay on the previous settled query until 200 ms after the last keystroke plus the lookup and one main hop, even when every match is in memory. A typist faster than 200 ms per key sees no narrowing at all until they pause. Empty and one-character queries settle synchronously (`FTSLookup.resolve` delivers `[:]` at once when nothing needs the index), so "never under 200 ms" is not quite right; the wait is for real queries.

**The in-memory half needs no index.** `MeetingFilterEngine.matchesQuery` is `if let ftsMatches, ftsMatches.contains(m.stem) { return true }` then `needles.allSatisfy { hay.contains($0) }` over `m.searchableText`, so FTS rows are ORed onto an in-memory match. With `ftsMatches` nil it searches the in-memory corpus alone. Quick Find already works this way: `QuickFindModel` re-ranks in memory on every change of `query` and applies `transcriptMatches` only while `transcriptMatches.query == query`, merging the FTS answer when it lands.

Correction at filing: the audit names "titles, workflow and app" as the in-memory matches. `MeetingStore.buildSearchableText` holds the summary title, the meeting title, the source app's display name and the summary's bullets, decisions, questions and action tasks; it has no workflow name. Workflow narrowing is a chip (`filter.workflow`), which `recomputeDerived` already applies at once because only the free-text half goes through `settled`. The title says title, app and summary text accordingly. (`SearchIndexer.documentBody`'s doc comment, "title + summary + source + workflow", overstates the corpus the same way.)

**The cost on the other side.** Re-deriving per keystroke means a `MeetingFilterEngine.apply` pass and a list re-diff per key. The filter pass is cheap (a substring check over one precomputed lowercased string per meeting, built once per scan), but the re-diff is what [PERF9](./PERF9.md) measured as a large share of the List's main-thread time while scrolling, so the debounce was also throttling list rebuilds.

Related: [UX103](./UX103.md) (batch actions on meetings the list no longer shows, and Quick Find's multi-word query) touches the same filter path; [PERF9](./PERF9.md) owns the list's own rendering cost.

## Scope

1. **Lift the typed-versus-settled decision into a pure function** beside `MeetingFilterEngine` (for example `LibrarySearchState.effective(typed:settled:) -> (query: String, ftsMatches: Set<String>?)`): the query is always the typed text; `ftsMatches` is the settled matches only when `settled.query == typed`, else nil. Passing the settled matches for a different query would OR the old query's transcript hits into the new list.
2. **`LibraryListView.recomputeDerived` uses it**, and `DerivedKey` includes the typed query, so a keystroke re-derives at once against the in-memory corpus. `resolveSearch` keeps the debounced lookup; its delivery bumps `settled.generation` as today, which re-derives with the transcript-depth rows merged.
3. **Optionally lower `FTSLookup.debounce`.** The lookup is off main and latest-wins, so a shorter debounce is safe for correctness, but the constant is shared with Quick Find and documents a 150 to 250 ms band from PERF20's spec. Change it only with a recorded reason; it is not part of acceptance.

## Explicitly not

- A searching indicator while a lookup is pending (P022's second gap): a UX call, not filed here.
- The list's rendering cost per re-derive: [PERF9](./PERF9.md). If per-keystroke re-derives make typing visibly heavier on a large library, the pickup records it there rather than reinstating the debounce for the in-memory half.
- Saved-folder lookups (`savedSearch?.filter.query`): unchanged, they already fall back to the in-memory corpus until their lookup lands.

## Acceptance

- Pure-function tests: typed equal to settled passes the settled matches; typed differing from settled passes nil; empty typed text passes nil.
- A `MeetingFilterEngine` or list-derivation test: with a lookup that has not delivered (injected `FTSLookup` with a hand-cranked scheduler, as `FTSLookupTests` does), typing a query that matches one meeting's title narrows the derived list to that meeting before the lookup resolves; when the lookup delivers a transcript-only match for the same query, that meeting joins the list; a delivery for a superseded query adds nothing.
- `FTSLookupTests` and the Quick Find tests stay green unchanged.
- `cd daemon && swift build` and `swift test` green, N new tests named in the commit body; `bash scripts/ci-local.sh` green.
