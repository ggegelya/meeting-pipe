# LANG2: One stray Cyrillic character disables the whole summary-language target

Band origin: filed 2026-07-31, off a miss the owner caught while running UX41's walkthrough: "summary in UA even tho meeting in english, I thought we fixed that". They were right on both counts, which is what makes this worth a task rather than a bug comment. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Meeting `20260730-163434` ("Kintava 5.12 Release, HIPAA CloudFront & Kintava 6 Update", 2026-07-30 16:34, header language EN) was re-summarized on 2026-07-31 at 13:43:41Z by `anthropic` / `claude-sonnet-4-6` as part of UX41's owner pass. The summary came back in Ukrainian: its first bullet reads "Heorhii завершив CloudFront setup для GMS (для відповідності HIPAA) та Sentry review rep...", and the stored `summary.json` carries **1,178 Cyrillic characters**.

The transcript it was generated from is English. Measured over `20260730-163434.json`: 22,213 characters of segment text, **25 Cyrillic letters against 17,222 Latin**, so Cyrillic is **0.14% of all letters**. Every one of those 25 is in a single throwaway opening line before the meeting starts ("Суть в том, что мне треба солнце"), and the remaining 30 minutes are English.

The cause is one line. `expected_summary_language(summary_language, transcript)` ends its Latin-dominant branch with:

```python
# Latin-dominant. LANG1: only a *pure* Latin transcript (zero Cyrillic) is a
# firm "en" target. Any Cyrillic mixed in means the meeting may legitimately
# carry another script, so leave it unverified rather than force English.
return "en" if cyr == 0 else None
```

`summary_language.py:106-109`. With `cyr == 25` the function returns `None`, which is the "cannot cheaply verify" answer, and `None` switches off everything LANG1 built: `language_reinforcement` is not added to the prompt, `divergent_sections` is not consulted, and the post-hoc repair never runs. The model was free to answer in any language and nothing was watching. Detection never failed; it was never asked.

**LANG1 (done 2026-07-10, archived in [q6-final.md](../q6-final.md)) is not regressed and this is not a reopen.** Its verifier, its per-section detection including `actions[].task`, and its backend-agnostic repair all work as built. The zero-Cyrillic gate is a deliberate conservatism recorded in its own comment, and its purpose is right: a genuinely code-switched meeting must not be force-flattened into one language. The defect is that the gate is absolute where the thing it is protecting against is proportional, so 0.14% noise is treated identically to a half-Ukrainian meeting.

## Scope

Replace the `cyr == 0` test in `expected_summary_language` with a share-based one, and give the Cyrillic-dominant branch the same treatment so the fix is symmetric rather than an English special case.

The threshold is the whole decision and it should be picked deliberately, not guessed: it needs to leave a meeting like this one (0.14%) verified as `en`, and leave a real code-switched meeting unverified. The corpus can inform it rather than intuition, since 244 recordings exist on disk and their transcripts can be scored for script share in one pass; a short script that prints the distribution of Cyrillic share across the library is cheap and would show whether the population is bimodal (mostly-pure meetings and genuinely mixed ones, with a gap to put the threshold in) or continuous. Record the chosen number and its justification in the function's comment, replacing the one quoted above.

`language_signature` carries the same `cyr >= lat` coarse split for its own purposes and should be reviewed in the same pass for consistency, but it answers a different question (what language is this text) and does not need the same threshold unless the review says so.

## Explicitly not / out of scope

**Not a change to `summary_language`'s config vocabulary.** `auto` and forced ISO codes stay as they are; `_VERIFIABLE_LANGS` is unchanged. Forcing `en` in config would work around this meeting and is not the fix, since the owner's library is genuinely multilingual and `auto` is the right default for it.

**Not a language-detection library.** The coarse script read is deliberate and sufficient; adding a dependency for this is out of proportion to the problem and the repo's dependency floor forbids it without asking.

**Not a re-summarize of the affected meeting as part of the fix.** That is a one-line owner action once the threshold lands, and it is in the walkthrough below rather than in the code.

**Not the `en` label's meaning.** `"en"` continues to mean "Latin script" rather than English specifically, and callers must keep not asking it to separate Latin languages (the existing docstring is explicit and stays).

## Acceptance

`test_summary_language.py` gains the regression case built from this meeting's real numbers: a transcript of ~17,200 Latin letters carrying 25 Cyrillic ones returns `"en"`, not `None`. A genuinely mixed transcript (a share above the chosen threshold) still returns `None`, and the existing zero-Cyrillic and Cyrillic-dominant cases keep their current answers, so the change is a widening of the verified set and not a re-specification.

The Cyrillic-dominant branch has the mirrored case: a Ukrainian transcript carrying a few Latin words still returns `"uk"`.

The chosen threshold appears once, as a named module constant beside `_LANG_MIN_LETTERS`, with the comment stating what it protects and what the corpus showed.

`cd pipeline && uv run --extra dev ruff check src tests`, `pyright`, and `pytest -q` green. No em-dashes in changed lines.

## Owner walkthrough (for the session that picks this up)

Per the 2026-07-30 standing rule: every task gated on an owner action carries one. Walk the owner through it step by step; the owner does not read code. Steps are tagged [owner] / [session] by who acts.

1. [session] Land the threshold, then re-summarize `20260730-163434` (Library, the 2026-07-30 16:34 meeting, Re-summarize with Anthropic).
2. [owner] Read the summary. Pass: it is in English. This is the meeting that produced the report, so it is the one that has to change.
3. [owner] Open two or three meetings that were genuinely conducted in Ukrainian or Russian and read their summaries. Pass: they are still in their own language. This step matters more than step 2: the easy way to "fix" this task is to force English everywhere, and that would quietly ruin every non-English meeting you have.
4. [owner] If you have a meeting that really does switch languages halfway through, read that one too and say which language its summary should have been in. There is no automatic right answer there, and your call is the only way to know whether the threshold sits in the right place.
5. [owner] Say "LANG2 good to close" (or what is wrong); [session] moves the row and the spec into `q6-final.md` and deletes this file.
