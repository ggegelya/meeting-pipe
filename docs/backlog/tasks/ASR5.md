# ASR5: spike, does FluidAudio's bundled CTC vocabulary boosting, fed by glossary terms and roster names, improve term recall on the owner's audio without hurting WER

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([go-live assessment](../../audits/2026-10-21-go-live-assessment.md) FQ-10, and its "Improving transcription and people identification" item 5, second half). Gated on [ASR4](./ASR4.md): there is nothing to measure against until its golden set and WER mode exist. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Verified on 2026-10-24:

- **The glossary is after-the-fact.** ASR1 (archived in [q6-final.md](../q6-final.md)) ships deterministic substitution at finalize (`mp.glossary`), and FEAT11 and FEAT12 gave it an editor and a correction-to-vocabulary path. It can only rewrite a term the ASR already produced in a recognisable wrong form. A name Parakeet splits into unrelated words, or drops, is out of its reach.
- **Boosting is in the pinned package and unused.** The FluidAudio 0.14.8 checkout carries `CustomVocabularyContext`, `CtcKeywordSpotter` and `VocabularyRescorer` under `ASR/Parakeet/SlidingWindow/CustomVocabulary/`, and its CLI applies them to a batch transcript (`TranscribeCommand`, `--custom-vocab`). Nothing in `daemon/Sources` or `daemon/Tests` references any of the three.
- **What upstream says it costs.** `Documentation/ASR/CustomVocabulary.md` in the checkout: Parakeet TDT 0.6B v3 has no CTC head, so it needs "Approach 2", a separately loaded Parakeet CTC 110M encoder (97.5 MB) and a second encoder pass (25.98x real time on their earnings benchmark, peak about 130 MB). The 99.4 percent "Dict Recall" upstream reports is on an English earnings-call set.

## What closes a priori, before any measurement

Per the `/spike` rule, settle these from the checkout and the model files first, and stop if any fails:

1. **Does the CTC 110M encoder cover Cyrillic?** The checkout's `Documentation/Models.md` describes `parakeet-ctc-110m-coreml` only as "CTC-based encoder for custom keyword spotting", with no language list, and its sibling TDT-CTC-110M is documented as English-only. Read its tokenizer vocabulary. If it has no Cyrillic pieces, boosting cannot help Ukrainian terms and the spike narrows to English and Latin-script names in code-switched meetings, which must be said in the verdict rather than discovered in the numbers.
2. **Does the batch path fit the runner?** Confirm the rescorer can run over the same 16 kHz mono samples `FluidAudioRunner.readMonoFloat32` already produces, after `AsrManager.transcribe`, without the streaming `SlidingWindowAsrManager`. The CLI suggests yes; verify against the API, not the CLI.
3. **Interaction with the language pin.** A pinned Cyrillic language makes `TokenLanguageFilter` prefer Cyrillic tokens ([UX85](./UX85.md)); a boosted Latin term may be filtered back out. State the order of operations.
4. **The download.** The CTC encoder is a new model fetch from HuggingFace. Prefetch, the SEC11 revision pin, and offline behaviour must be named before anything ships.

## Measurement

On ASR4's golden set, with the term list built from the glossary's right-hand terms plus enrolled roster names (`GlossaryStore` and the roster the daemon already reads), compare boosting off against on, per language subset: term recall, WER, CER, and the added wall-clock time per audio minute.

## Pre-registered verdict thresholds

Written 2026-10-24, before any number exists. Report against them as written.

| Verdict | Measured | Next |
|---|---|---|
| **GO** | Term recall up by 15 points or more on at least one subset, and WER worse by no more than 0.5 points on every subset, and added time under 25 percent of today's transcription time | File the integration task (runner seam, term-list source, prefetch, a Preferences toggle default off), with the owner |
| **MARGINAL** | Term recall up by 5 to 15 points with the same WER and time bounds | Record the numbers; no integration unless the owner asks |
| **NO-GO** | Anything else, or a priori item 1 or 2 fails | Close; the post-ASR glossary stays the only vocabulary lever |

## Explicitly not

- Shipping boosting in the product. This spike's deliverable is a measurement and a verdict; integration is a separate filing on GO.
- Switching to the TDT-CTC-110M model (built-in CTC head, cheaper boosting). The checkout's `Documentation/ASR/TDT-CTC-110M.md` lists its languages as English against v3's 25 European, so it would drop Ukrainian.
- Changing `mp.glossary` or the finalize-time contract. If boosting goes in, the glossary still runs after it.
- Roster or naming changes ([FEAT19](./FEAT19.md)).

## Deliverables and acceptance

- `docs/spikes/asr5-vocabulary-boosting.md` with the question, the four a priori items and their answers with citations, the thresholds table copied verbatim, and the owner's exact command.
- An owner-run probe (its own SwiftPM package under `daemon/scripts/`, the DIAR4 precedent, so `daemon/`'s build is untouched) that runs both arms over the golden set and prints the table above as counts and rates, no transcript text. An empty golden directory prints "nothing scanned" and exits non-zero.
- No production code changes. `python3 scripts/truth_fences.py both` green.
- The verdict read off the table without adjusting it, recorded in the spike doc.
