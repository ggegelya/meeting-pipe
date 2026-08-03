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

## As built (2026-08-04)

`expected_summary_language`'s `cyr == 0` test is replaced by one symmetric constant beside `_LANG_MIN_LETTERS`:

```python
_LANG_MAX_MINORITY_SHARE = 0.33
```

Both branches now reject before they read the script: a transcript whose minority script is more than a third of its letters returns `None`, and only then does the Cyrillic-dominant branch do its uk-vs-ru read. Read plainly: a transcript is a firm target only when at least two thirds of its letters are one script, whichever script leads.

### How the number was chosen, and the mistake worth recording

The corpus was scored, per the Scope section's suggestion. The first pass measured the raw segment text of 208 transcripts and landed on **20%**, which looked well supported: the Cyrillic-dominant meetings topped out at 10.8% Latin and the one genuinely bilingual meeting sat at 46.8%, so 20% had margins of 1.8x and 2.3x.

**That measured the wrong text.** `summarize` hands the function `transcript`, which is the *rendered markdown* (speaker labels, header, timestamps), not the segment text. Re-scored on the markdown across all 232 transcripts on disk, the picture moves:

| Group | Count | Minority-script share (markdown) |
|---|---|---|
| Single script exactly | 205 | 0% |
| Cyrillic-dominant | 19 | 0.9% to **23.1%** |
| Latin-dominant, not bilingual | 7 | 0.1% to 1.4%, plus one at 8.0% |
| Genuinely bilingual | 1 | **45.2%** |

At 20% one real Ukrainian meeting (`20260730-163033`) would have lost its verified `uk` target, which is exactly the damage the walkthrough's step 3 exists to catch, reached from the other side. The window is therefore **(23.1%, 45.2%)**, and 0.33 sits 1.43x above the ceiling and 1.37x below the bilingual meeting, about as centred as the data allows.

The two sides differ in kind, not only in degree, which is why one number covers both. In a Ukrainian meeting the Latin minority is borrowed technical vocabulary interleaved word by word (Jenkins, Docker, tenant, API), longest contiguous Latin run 14 words. In an English meeting the Cyrillic minority is somebody actually speaking Ukrainian for a stretch, contiguous runs of 35 to 94 words. The one bilingual meeting is 1,637 Cyrillic words in a single 281-word run and half the transcript.

### Verified against the whole library

Old answer against new, over all 232 transcripts: **7 meetings change, every one of them `None -> en`, and none loses a target.** A pure widening, as the Acceptance section asked for. The seven sit at 0.10%, 0.14% (the subject meeting), 0.59%, 0.75%, 0.81%, 1.37%, and 7.97%. On `20260730-163434` specifically the target is now `en`, and all five sections of the summary it shipped flag as divergent, so LANG1's repair fires on the exact meeting that produced the report.

### `language_signature`: reviewed, deliberately unchanged

It keeps the plain majority split. It answers a different question over much shorter text, and its callers are the per-section checks in `divergent_sections`. The owner's real Ukrainian summaries carry **20% to 37% Latin per section**, with one title at 49%, because that is where the product names live. Gating it on the same share would return `None` for most of them, and a section the detector will not read is a section `divergent_sections` will not flag, which is LANG1's whole mechanism switched off. Fail-safe is the wrong instinct here: a missed flag costs a summary in the wrong language, a wrong flag costs one model call that is discarded unless it comes back clean.

### One finding this task does not fix

The 23.1% ceiling that pins the threshold is **not linguistic**. That meeting's speech is 5.7% Latin; the rest is the markdown wrapper, whose `# Transcript - <stem>` header and one `**Name**:` label per turn are Latin whatever the meeting was spoken in. It is a fixed cost per turn, so it lands hardest on the shortest meetings (that one is ~3 minutes, and 174 of its 218 Latin letters are labels) while the longest Cyrillic meeting barely moves (0.4% to 0.9%). Two consequences, both recorded in the constant's comment: erring low is the safer error, since a threshold set too low costs a short meeting its safety net and leaves it where it was before LANG1, while one set too high forces a genuinely bilingual meeting into a single language, which is an actively wrong answer rather than an absent one; and a still shorter Cyrillic meeting could clear 33% on labels alone, whose fix is to stop counting the wrapper rather than to keep raising this constant. Worth its own task if it ever bites.

## Owner walkthrough (for the session that picks this up)

Per the 2026-07-30 standing rule: every task gated on an owner action carries one. Walk the owner through it step by step; the owner does not read code. Steps are tagged [owner] / [session] by who acts.

1. [session] Land the threshold, then re-summarize `20260730-163434` (Library, the 2026-07-30 16:34 meeting, Re-summarize with Anthropic).
2. [owner] Read the summary. Pass: it is in English. This is the meeting that produced the report, so it is the one that has to change.
3. [owner] Open two or three meetings that were genuinely conducted in Ukrainian or Russian and read their summaries. Pass: they are still in their own language. This step matters more than step 2: the easy way to "fix" this task is to force English everywhere, and that would quietly ruin every non-English meeting you have. If you want the ones with the most English mixed in, since those are where a bad threshold would show first, they are the 2026-06-18 11:31 and 2026-07-14 16:20 meetings, plus the short 2026-07-30 16:30 one.
4. [owner] The corpus scan found exactly two meetings that really do switch languages, and they now get opposite answers. Read both and say whether that is right. **2026-05-21 16:30** (`20260521-163051`) is mostly English with one Ukrainian stretch of about 66 words, and now gets an English target, so its summary will be steered to English. **2026-06-11 11:32** (`20260611-113210`) is about half and half, and is deliberately left alone, so its summary comes out in whatever language the model picks. There is no automatic right answer for either, and your call is the only way to know whether the threshold sits in the right place. If the first one should have stayed Ukrainian, the constant comes down; if the second should be pinned to one language, it goes up.
5. [owner] Say "LANG2 good to close" (or what is wrong); [session] moves the row and the spec into `q6-final.md` and deletes this file.
