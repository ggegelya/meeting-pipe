# FEAT13: Clarify a misheard word where you find it, not in Preferences

Band origin: filed 2026-07-31 at the owner's request, immediately after FEAT11's vocabulary walkthrough made the friction concrete: "I want to have an easy mechanism to 'clarify' things on the flight, not with 'Settings -> Pipeline'. I think it would be nice to select words with mouse, see automatically menu 'Clarify' or something, then enter the clarification, and save it with options to re-transcribe or whatever." Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

FEAT11 shipped the vocabulary editor at Preferences ▸ Pipeline ▸ Vocabulary, and it works: on 2026-07-31 the owner added `sitting environment` to `staging environment`, ran Re-transcribe on `20260723-103118`, and the garble was gone. The friction is where the surface lives. A misheard word is discovered while reading a transcript, and fixing it means leaving the transcript, opening Preferences, finding the pane, retyping a phrase from memory, closing Preferences, and returning to run Re-transcribe.

**This was anticipated and deliberately parked.** FEAT11's spec records it as not built: "the optional *add to vocabulary* pre-fill off PIPE9. Reason in the ToC row. If it is ever picked up, the constraint that decides its shape is the spec's own 'keep it a pre-fill, not an auto-write', which the current store cannot express (every write is live)." This task is that pickup, and the constraint is the most valuable thing carried forward.

**The same session produced the argument for that constraint.** The meeting also contained the word "Venusaur", which the ASR invented and which neither the owner nor the session could decode ("Venusaur I cannot understand myself what was speaking about"). Under an auto-write, selecting it and clarifying would have written a permanent global rule rewriting every future transcript on a guess. Under a pre-fill, the owner saw it and walked away, which is what actually happened. A Clarify affordance that writes on confirm is the whole feature; one that writes on selection is a corpus hazard.

The seam already exists on both sides. The transcript is already editable in place: `TranscriptTab` says "Click a line to edit or seek", and `TranscriptCorrectionStore` (PIPE9) persists a per-segment text overlay to `<stem>.transcript_corrections.json`. The vocabulary side is `GlossaryStore` over `glossary.toml` (FEAT11), whose resolution is mirrored by `mp.glossary` and pinned by a CI4 fixture.

## The design question this task exists to answer

**A per-meeting text fix and a global vocabulary rule are different things with different blast radii, and Clarify touches both.** Correcting one line changes one meeting and is trivially reversible. Adding a glossary term changes every transcript finalized from then on, including meetings not yet recorded. Collapsing them behind one button is the failure mode to avoid.

The affordance should therefore offer both, visibly distinguished, in the register of "fix it here" versus "always fix this". Which of the two is the default, and whether "always" implies "here" as well, is the call to make at pickup and to record. A reasonable starting position, to be challenged rather than assumed: fixing here is the safe default because it is per-meeting and reversible, and promoting to a rule is the deliberate extra step.

The re-transcribe offer the owner asked for ("save it with options to re-transcribe or whatever") belongs on the rule path only. A per-meeting text correction is already applied by the overlay and needs no re-run; a new glossary term only reaches existing transcripts through Re-transcribe, and that is exactly the confusion FEAT11's walkthrough had to warn against ("not Reprocess and not Re-summarize: both re-run over the transcript already on disk").

## Scope

A selection-driven Clarify affordance in the transcript that pre-fills a small editor with the selected text as the "as heard" side, takes the intended text, and offers the two destinations above. On the rule path, offer Re-transcribe for the current meeting once the term is saved.

Nothing is written until the user confirms. The FEAT11 note that "the current store cannot express" a pre-fill is the real work here: `GlossaryStore`'s writes are live, so a staged, uncommitted entry either needs the store to grow that concept or needs the editor to hold the pair until confirm and write once. Prefer the latter if it keeps the store simpler, since a store with a draft state is a store two surfaces can disagree about.

## Explicitly not / out of scope

**Not an auto-write on selection**, and not a "learn from my corrections" inference. FEAT11 already parked corpus mining ("auto-suggested glossary terms from the corrections corpus") and the Venusaur case above is the argument against inferring rules from garbles.

**Not a replacement for the Preferences editor.** That surface stays: it is where the whole table is reviewed, edited and pruned, which a per-selection affordance cannot do.

**Not fuzzy matching or per-workflow scoping changes.** `[fuzzy]` and the per-workflow term tables are FEAT11's and are unchanged; a term added here goes global unless the editor offers the existing scope choice, which it may.

**Not speaker naming.** The cast strip's chips are their own affordance (UX40) and are not folded in.

## Acceptance

Selecting text in a transcript row offers Clarify. Choosing it opens an editor pre-filled with the selection, and **nothing is persisted until confirm**: a test pins that opening and dismissing the editor leaves both `glossary.toml` and `<stem>.transcript_corrections.json` byte-identical.

The two destinations are distinguishable in the UI and in the tests: confirming the per-meeting fix writes only the correction overlay; confirming the rule writes only the glossary term (or both, if that is the recorded decision), and the rule path offers Re-transcribe while the per-meeting path does not.

A term added through Clarify resolves identically to one typed in Preferences, so the CI4 `glossary-golden.json` fixture and `mp.glossary` still agree; regenerate the fixture if the writer changes (`cd pipeline && uv run python ../scripts/gen_contract_fixtures.py`).

`cd daemon && swift build` and `swift test` green. `python3 scripts/truth_fences.py both` green. No em-dashes in changed lines.

## Owner walkthrough (for the session that picks this up)

Per the 2026-07-30 standing rule. Steps are tagged [owner] / [session] by who acts.

1. [session] `./scripts/rebuild.sh`, then tell the owner it is ready.
2. [owner] Open a transcript, select a misheard word or phrase with the mouse. Pass: a Clarify option appears without hunting for it.
3. [owner] Open it and read what it offers. Pass: it is pre-filled with what you selected, and it is obvious which choice changes only this meeting and which changes every future transcript. **Judge that wording as writing**: it is the only thing standing between a one-line fix and a permanent rule.
4. [owner] Dismiss it without confirming, then check Preferences ▸ Pipeline ▸ Vocabulary. Pass: nothing was added. This is the step that matters most, and the reason it exists is Venusaur: a garble you cannot decode must be walk-away-able.
5. [owner] Now do it for real on a word you are sure about, choosing the per-meeting fix. Pass: that line reads correctly and no vocabulary entry appeared.
6. [owner] Do it again choosing the rule, and accept the Re-transcribe it offers. Pass: the term is in Preferences ▸ Pipeline ▸ Vocabulary and the meeting comes back corrected.
7. [owner] Say "FEAT13 good to close" (or what is wrong); [session] moves the row and the spec into `q6-final.md` and deletes this file.
