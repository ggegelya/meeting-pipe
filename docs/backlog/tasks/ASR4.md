# ASR4: transcription accuracy has never been measured on the owner's audio, and no test runs ASR or diarization inference, so there is no regression net for the speech stack

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) FQ-9, QG-9, and its "Improving transcription and people identification" item 5, first half). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Verified on 2026-10-24:

- **No accuracy measurement exists.** `scripts/valid1_check.py` has `--ux4`, `--diar` (latency), `--attribution`, `--der` (a misattribution lower bound from in-app corrections, or a real DER with `--reviewed`), `--cleanup`, `--coldstart` and `--timings`. Its header says a true diarization error rate and summary quality "stay human reads". There is no word error rate anywhere in `scripts/` or `pipeline/src`. The only accuracy figures the repo cites for Parakeet TDT v3 are upstream's (FLEURS read speech, about 5.4 percent English and 7.2 percent Ukrainian, per the go-live read), which say nothing about bilingual, code-switched, multi-party meeting audio.
- **No test runs inference.** The only `FluidAudioRunner()` constructed in `daemon/Tests` is in `FluidAudioRunnerCancellationTests`, which cancels before the models load by design. `SinkDispatcherTests` uses a fake runner. `pipeline/tests` never touches audio inference (ASR moved to Swift, ADR 0007). Everything after the WAV is tested against synthetic tokens and spans, so a FluidAudio bump, a mixdown change, or a `SegmentBuilder` change can move real transcripts with every suite green.
- **What is known about loss** comes from the go-live read: 0.7 to 8 percent of energy-active seconds fall outside any segment, longest gap 1 to 4 s. That is coverage, not correctness.

Four filed tasks need a before-and-after number this task would provide: [DIAR6](./DIAR6.md) (gain normalization), [DIAR7](./DIAR7.md) (word-level assignment), [ASR5](./ASR5.md) (vocabulary boosting, gated on this), and any FluidAudio bump ([ASR6](./ASR6.md), LOCAL5's deferred 0.15.x).

## Scope

1. **A golden set, owned by the owner and kept out of the repo.** 30 to 60 minutes of the owner's own audio, split across English, Ukrainian and code-switched meetings, each with a hand-corrected reference transcript. It lives under a path outside the repository (for example `~/.config/meeting-pipe/golden/`), because it is meeting content. A manifest per clip names the audio, the reference, the language subset, and optionally reference speaker turns. The cheapest way to produce a reference is the app's own correction flow over a meeting the owner reviews in full (the `--der --reviewed` idea), frozen into the golden directory so a later Re-transcribe cannot shift it. A first cut of three 5-minute clips (one per subset) is acceptable to ship the harness against; the full set can grow later.
2. **A hypothesis run through production code.** An opt-in XCTest in `daemon/Tests` that, when an environment variable points at the golden directory, runs the shipped `FluidAudioRunner.transcribe` (so the real mixdown, Parakeet, diarizer, `SegmentBuilder.build` and `coalesce`) over each clip and writes hypothesis sidecars to a temporary directory. Unset, it reports that it was not configured; it must not write into the real library or `~/Library/Logs/MeetingPipe` ([T9](./T9.md)). An env-gated test rather than a new subcommand on the shipped binary, so no dev surface ships as product ([PIPE20](./PIPE20.md)'s class).
3. **A WER mode.** `scripts/valid1_check.py --wer <golden dir> <hypothesis dir>`, stdlib only like the rest of the script: word-level edit distance after a documented normalization (Unicode NFC, casefold, punctuation stripped), reported per clip and per language subset, plus character error rate for the Ukrainian and code-switched subsets, plus term recall over a supplied term list (the glossary's right-hand terms and roster names, which is ASR5's metric). When reference speaker turns exist, a DER over the same clips. Output carries counts and rates only, never transcript text, so it can be pasted into a session (the FEAT17 privacy rule).

## Explicitly not

- Committing any of the owner's audio or text, or running the golden set in CI. CI cannot hold the content and has no cached models.
- A public-audio inference smoke test in CI (a short CC-licensed clip with a loose WER bound). Worth considering under [CI9](./CI9.md) once this harness exists; it needs a licence check and a model-download decision, both owner calls.
- Changing any model, threshold or mixdown. This task builds the instrument and records the baseline; DIAR6, DIAR7 and ASR5 move things.
- Replacing `--der`. The lower bound from corrections stays; the golden DER is the stronger reading beside it.

## Acceptance

- `scripts/valid1_check.py --wer` exists with tests for the pure scoring functions (edit distance, normalization, CER, term recall), including a Cyrillic case and a code-switched case; an empty or missing golden directory prints a distinguishable "nothing scanned" and exits non-zero, never a zero WER.
- The golden XCTest skips with a clear message when unconfigured, and when configured writes hypotheses only under a temporary directory (asserted).
- The manifest format and the golden directory's location are documented in `CONVENTIONS.md` (or a short `docs/` page linked from it).
- `cd daemon && swift build` and `swift test` green; `python3 scripts/truth_fences.py both` green; new test counts in the commit body.
- Owner-run, after merge: the first baseline (WER, CER and term recall per subset, golden DER if turns exist) recorded in the ship note, as the number DIAR6, DIAR7 and ASR5 are judged against.
