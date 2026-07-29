# FEAT12: Add to Vocabulary from a transcript correction

Band origin: filed 2026-07-29 (owner exploratory sweep, items 15/16; the invisible-capability inventory ranked this the highest-leverage missing bridge). Revisits the optional leg FEAT11 (shipped 2026-07-28) deliberately did not build; its scope note records why, and those reasons are honored below as constraints. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

The Vocabulary teaches the transcriber recurring fixes, but the only way terms get in is a user remembering a garble, opening Preferences, and typing both sides from memory. The moment they actually know the pair is when they fix it in the transcript: the segment context menu's "Edit text..." (`TranscriptTab.swift:849-887`) writes a correction record with the original and edited text (`TranscriptCorrectionStore`), and that knowledge is then discarded. FEAT11's own vocabulary editor cannot benefit from the corrections the product already captures.

FEAT11 skipped this leg for named reasons (backlog row, 2026-07-28): honoring "keep it a pre-fill, not an auto-write" needs an uncommitted-row concept in the store plus a word-diff over the edit, real complexity for a `may` leg. The owner's non-technical-use framing (2026-07-29) changes the value side of that trade, not the constraints: it stays a pre-fill, and the diff stays deliberately dumb.

## Scope

- A pure word-diff helper: given (original, edited) segment text, produce at most one candidate pair when the edit is a single-token or short-span replacement (case-insensitive compare, punctuation-tolerant), and bail (no candidate) on anything larger: multi-word rewrites, insertions, deletions, reordering. Bailing is a feature; a wrong vocabulary pair silently corrupts future transcripts.
- The affordance: after a transcript text edit saves and the diff yields a candidate, offer "Add 'X' to Vocabulary as 'Y'..." in the edit flow's confirmation moment (and/or a standing "Add to Vocabulary..." item in the segment context menu that opens pre-filled from that segment's correction). Clicking opens the pre-filled pair with the scope defaulted to the meeting's workflow (fall back to global when the meeting has none); the user confirms; only then does `GlossaryStore` append. Nothing is ever written without the explicit confirm (FEAT11's honesty rule, restated as this task's hard constraint).
- The pre-fill lands through the same `GlossaryStore` append path the editor uses (no second writer), and the editor shows the new row on next open.
- Copy stays in the UX44 register (no "ASR").

## Explicitly not in scope

Auto-writing pairs from corrections, ever (rejected in FEAT11 and re-rejected here; recorded so pickup does not soften it). Mining historical corrections in batch to seed the vocabulary (a real idea, noted as an adjacency for the owner to commission separately; it has different consent and review needs). Fuzzy-match suggestions. Changing correction storage or `mp.glossary` semantics.

## Acceptance

Pure diff tests: single-token replacement yields the pair (with original casing preserved on the canonical side); a cased variant matches case-insensitively; punctuation-adjacent tokens tolerated; two-token span replacement yields the pair only when contiguous; insertions, deletions, and multi-span edits yield no candidate (each pinned).

Flow tests: the affordance appears only when a candidate exists; confirming appends exactly one row to the right scope via the shared store path; cancelling writes nothing (store contents pinned unchanged).

`cd daemon && swift build` and `swift test` green (baseline at filing: 1770). Repo dash guard green.

Owner eyeball: fix a garbled product name in any transcript line; the offer names the exact pair; confirm; Preferences, Pipeline, Vocabulary shows it under the meeting's workflow; Re-transcribe that meeting and the garble is gone (the FEAT11 acceptance loop, now reachable in three clicks).
