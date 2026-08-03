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

## Shipped 2026-08-03

Everything above the owner eyeball is done. `swift build` clean, `swift test` 2052 passing against a 2029 baseline measured on this branch; the spec's 1770 was two months stale, so the delta is +23, not +282.

**What landed.** `daemon/Sources/MeetingPipe/VocabularyCandidate.swift` is the pure half: `VocabularyCandidate.derive(original:edited:)` names at most one pair, and `VocabularyOffer.make` wraps it with the scope default. `TranscriptTab.saveCorrection` builds the offer after a line edit persists, the edit sheet's `onDismiss` hands it to a new `VocabularyOfferSheet`, and only that sheet's **Add** calls `GlossaryStore.addTerm(heard:canonical:workflow:)`, a new entry point that is the Preferences editor's own scope-then-mutate steps collapsed into one call.

**How the diff decides.** Tokens are compared exactly; edge tokens of the changed run that differ only in case are then trimmed off it. That two-step is what keeps a re-capitalized neighbour ("the" to "The") from widening a one-word fix into a two-word pair, while still letting a pure capitalization fix stand when it is the whole edit. It refuses: unequal token counts (every insertion and deletion), a run longer than two tokens, a change split across two places, a same-words reorder, and a pair that trims to the same string on both sides (a punctuation-only tweak).

**Both hard constraints held, and are pinned rather than asserted.** `VocabularyCandidateTests` (23 cases) covers every acceptance clause; `test_making_an_offer_writes_nothing` is the cancel case and pins the glossary file byte-for-byte, which states the pre-fill rule as a fact about the code rather than about the UI wiring. `test_confirming_preserves_the_knobs_the_editor_does_not_model` pins that `[fuzzy]` survives an add, which is the payoff for routing through `GlossaryStore` instead of writing a second time.

**Two decisions the spec left open.**

1. The affordance is the post-save sheet **only**, not the "and/or" standing context-menu item. The confirm moment is where both sides of the pair are known, so it is the leg that earns its complexity; the menu variant would need each row to know whether its segment carries a correction, which is plumbing the row does not have today. If the owner wants a second way in after living with this, it is a small follow-up rather than a rework.
2. A pure capitalization fix counts as a pair. Keys are folded at match time and values are not, so "kubernetes" to "Kubernetes" is a substitution that actually does something to every future transcript, and refusing it would have been the surprising behaviour.

**One race, named rather than fixed.** The sheet's confirm builds its own `GlossaryStore` so the document it merges into is read at confirm time. A Preferences window sitting open on the Vocabulary group mid-keystroke has a 500 ms debounce pending that would then write its own document over this one, costing the term (not the file). Closing that properly means shared ownership of the store, which is a larger change than this leg is worth; it is commented at the call site.

## Owner walkthrough (for the session that picks this up)

Every task gated on an owner action carries one (2026-07-30 rule). Walk the owner through it step by step; the owner does not read code. Steps are tagged [owner] / [session] by who acts.

1. [session] Install the build so the Library has the new sheet: `./scripts/rebuild.sh` from the repo root.
2. [owner] Open the Library, pick any meeting whose transcript contains a mangled product or person name, and open its **Transcript** tab. If nothing obvious is there, any single word will do: the check is about the mechanism, not about the word being genuinely wrong.
3. [owner] Hover the line and click the pencil (or right-click and pick **Edit text…**). Change exactly **one** word, leaving the rest of the line alone, and press **Save**.
4. [owner] A second sheet should appear, titled **Add to Vocabulary**, with the old spelling on the left and the new one on the right. Read both boxes: they must name the exact pair you just changed and nothing else. If a whole phrase shows up instead of the one word, stop and say so, because that is the diff being less dumb than it is supposed to be.
5. [owner] Check the **Applies to** row. It should already read this meeting's workflow name. A meeting with no workflow shows the line "Applies to every meeting." instead, with no picker, which is also correct.
6. [owner] Press **Cancel** the first time, on purpose. Nothing should have been written.
7. [session] Confirm that: `grep -c . ~/.config/meeting-pipe/glossary.toml` before and after should match, or the file should still not exist if there were no terms. This is the honesty rule, checked once by hand.
8. [owner] Repeat steps 3 and 4, and this time press **Add**.
9. [owner] Open **Preferences ▸ Pipeline ▸ Vocabulary** and set **Applies to** to that meeting's workflow. The new pair should be listed there. Switching **Applies to** back to **Every meeting** should not show it, since it was scoped to the workflow.
10. [owner] Back in the Library, run **Re-transcribe…** from that meeting's `...` menu. It costs no engine call and keeps the existing summary. When it finishes, the garbled word should be spelled correctly in the transcript, without your line edit being what fixed it.
11. [session] If steps 4, 9, and 10 all hold, FEAT12 moves to done and its spec archives into `q6-final.md`. If step 4 named the wrong pair, that is a `VocabularyCandidate.derive` bug and the failing line pair belongs in a test before anything is changed.
