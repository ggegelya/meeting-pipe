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

## Shipped 2026-08-04

Everything above the owner walkthrough is done. `cd daemon && swift build` clean, `swift test` green with 22 new tests (`ClarifyTests`), `python3 scripts/truth_fences.py both` green, no em-dash in any changed line. The CI4 `glossary-golden.json` fixture was **not** regenerated and did not need to be: the glossary writer is untouched, this task's rule path calls FEAT12's existing `GlossaryStore.addTerm`, and `CI4ContractFixtureTests` passes as it stood.

**What landed.** `daemon/Sources/MeetingPipe/Clarify.swift` is the pure half: `Clarify.Destination` (the two blast radii plus their copy), `Clarify.Plan` (one case per destination), `Clarify.plan(…)`, and `Clarify.substitute`. `ClarifySheet.swift` renders it. `TranscriptTab`'s row context menu gained **Clarify a word…** directly under **Edit text…**, and the host gained a `clarifyTarget` sheet plus `applyClarify`, which routes each plan to exactly one writer.

### The entry point is not the one the spec asked for, because that one cannot fire

The spec's shape was "select words with the mouse, get a Clarify option". **Measured first, per the pickup instruction, and it is not available on this stack.** An on-screen `NSWindow` probe hosting `Text(…).textSelection(.enabled)` (extending UX48's offscreen one) reports that SwiftUI's `SelectionTextField`:

- answers `acceptsFirstResponder` **false**, and `makeFirstResponder(field)` leaves the **window** as first responder;
- engages **no field editor** (`window.fieldEditor(false, for:)` is nil);
- returns **nil** from `validRequestor(forSendType: .string, returnType: nil)`, before and after a `selectAll`.

That closes UX48's own hedge from the other side. Its escape route was that a selectable `NSTextField` conventionally engages the window's field editor, which *is* an `NSTextView` with the standard text menu, so a right-click after selecting might find what a right-click before selecting does not. No field editor is ever engaged, so there is nothing to find, and there is no `NSServicesMenuRequestor` to hand the selection over either. SwiftUI owns the selection privately in a `PlatformViewRepresentableAdaptor<SelectionOverlay>` and exposes no accessor on the macOS 14 floor.

**One workaround was considered and rejected rather than shipped.** Since UX48 installed a main menu whose Copy has a nil target, `NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)` plausibly *would* put the live selection on the general pasteboard, and the sheet could read it, verify it occurs in this line, and restore the pasteboard afterwards. It was turned down: it puts the owner's clipboard at risk (a restore cannot faithfully rebuild lazily-provided or custom types) to save typing one word, it is untestable, and it depends on private behaviour that an OS update can change silently. If the owner wants it after living with the shipped shape, it is a small follow-up with a stated cost, not a thing to have guessed at now.

So the affordance is the transcript row's own `.contextMenu`, which is proven to open over transcript text (it is where **Edit text…** and **Assign to…** already live). Walkthrough steps 2 and 3 below are rewritten to match; the durable measurement is recorded in `daemon/CLAUDE.md` so no later session re-derives it.

### The three calls the spec left open

1. **The per-meeting fix is the default.** The spec's own starting position, adopted rather than overturned: it is the reversible, one-meeting option, and promoting to a rule should cost a deliberate second click.
2. **"Always" does not imply "here".** The rule path writes the term and **only** the term. Writing the overlay alongside was rejected for a reason worth keeping: an overlay laid over a term makes a rule that never matched look like it worked, so the owner would have no way to tell a live term from a dead one. It also keeps each choice one-to-one with one write, which is the honesty the whole task is about, and keeps FEAT12's shipped sheet copy true rather than contradicted.
3. **Re-transcribe is a tick box inside the sheet, on the rule path only, defaulting off.** The owner asked to "save it with options to re-transcribe", and pre-registering the choice beats a second modal after the fact. Its presence is itself the visible discriminator between the two paths. Off by default because a rebuild spends minutes of the Mac's time, and a sheet that starts a job nobody asked for is the same class of surprise as a rule written without a confirm. There is no second confirmation once it is ticked: the tick was the ask, and re-asking is the friction this task exists to remove.

### Two smaller decisions

`Clarify.substitute` deliberately mirrors `mp.glossary`'s `\b(<key>)\b` case-insensitive, every-occurrence substitution (`glossary.py:70`), **including its limitation** that a term ending in punctuation ("c++") anchors nowhere and matches nothing. `test_wording_ending_in_punctuation_matches_nothing_here_or_in_the_pipeline` pins that on purpose: making the line path cleverer than the rule path would mean "Fix this line only" fixing a line that "Always fix this" could never fix, which is exactly the confusion between the two blast radii the task exists to prevent. The line path also refuses a substitution that would not change the line, so Clarify cannot write a no-op overlay entry that later shows up in a re-transcribe's carry report as work to preserve.

`LibraryDialogs.reportRetranscribe` is the re-transcribe result dialog, promoted out of `MeetingDetailView+Header`'s private scope because this task gave it a second caller. A carry that dropped an override has to read the same wherever the rebuild was started from, and a private copy per caller is how the Trash confirm came to be worded two different ways for the same action.

**One thing deliberately not done:** no new event action. A Clarify-driven write emits the same `transcript_correction` / `vocabulary_term_added` events the other surfaces do, because it is literally the same write through the same store; a Clarify-specific action would have been a second name for one thing.

## Owner walkthrough (for the session that picks this up)

Per the 2026-07-30 standing rule. Steps are tagged [owner] / [session] by who acts.

1. [session] `./scripts/rebuild.sh`, then tell the owner it is ready.
2. [owner] Open a transcript and **right-click** a line with a misheard word in it. Pass: **Clarify a word…** is there, directly under **Edit text…**. (It is a right-click and not a mouse selection, and that is not a shortcut taken: the app cannot see what you selected. The measurement is above.)
3. [owner] Open it and read what it offers. Pass: the line you right-clicked is shown at the top so you can read the wrong words straight off it, and it is obvious which choice changes only this meeting and which changes every future transcript. **Judge that wording as writing**: it is the only thing standing between a one-line fix and a permanent rule.
4. [owner] Dismiss it without confirming, then check Preferences ▸ Pipeline ▸ Vocabulary. Pass: nothing was added. This is the step that matters most, and the reason it exists is Venusaur: a garble you cannot decode must be walk-away-able.
5. [owner] Now do it for real on a word you are sure about, choosing the per-meeting fix. Pass: that line reads correctly and no vocabulary entry appeared.
6. [owner] Do it again, this time choosing **Always fix this**, and tick **Re-transcribe this meeting afterwards** before pressing the button (it starts off, on purpose). Pass: the term is in Preferences ▸ Pipeline ▸ Vocabulary, the rebuild runs on its own without asking a second time, and the meeting comes back corrected. If a text edit of yours could not be re-anchored the report says how many were dropped, which is expected behaviour rather than a fault.
7. [owner] Say "FEAT13 good to close" (or what is wrong); [session] moves the row and the spec into `q6-final.md` and deletes this file.
