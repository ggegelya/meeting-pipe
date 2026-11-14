---
id: FEAT25
title: Clarify's 'Always fix this' accepts common words and case-only pairs as global rules, and stores a normalised key the user never sees
category: Transcription
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). The rule path refuses only empty or identical sides, so a pronoun-to-acronym fix becomes a global rule rewriting every future transcript, a key that can never match is saved silently, and the trimmed key is never shown; FEAT12's offer sheet writes the same file with even fewer checks; not observed in the field (no correction events in the window). One pure rule check shared by both sheets: refuse stop-words and keys with no word-character edge, warn on case-only and very short keys, show the saved key and a match count over this meeting.
---

# FEAT25: Clarify's 'Always fix this' accepts common words and case-only pairs as global rules, and stores a normalised key the user never sees

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: finding G016 in the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md) (quality lens, confirmed). Re-verified in code at HEAD `3a2da4fc` on 2026-11-13; the defect holds, with one correction and one widening below.

**The rule path's only gate.** `Clarify.plan` normalises with `let heard = VocabularyCandidate.trimPunctuation(rawHeard)` and then `guard !heard.isEmpty, !intended.isEmpty, heard != intended else { return nil }`. On `.everyMeeting` it returns `.addTerm` with no further check, and the sheet's **Add Term** button is enabled exactly when `plan` is non-nil. `heard != intended` is case-sensitive, so a pair that differs only in case passes.

**Why a case-only pair on a common word is dangerous.** `mp.glossary.Glossary` folds keys (`terms` maps a lower-cased key) and compiles `\b(<keys>)\b` with `re.IGNORECASE`, replacing every match with the canonical spelling. A pronoun typed as the heard side and an all-caps acronym as the intended side therefore rewrites that pronoun in every line of every transcript finalised later in that scope. `GlossaryStore.addTerm` folds only to find an existing row with the same key; it stores the key as given, and the fold happens at match time on both sides. The audit replayed `glossary.py`'s regex on a two-sentence sample and got the acronym in place of every pronoun.

**Keys that can never fire are saved silently.** `Clarify.substitute` and `containsTerm` share `wordRegex`, `\b<escaped>\b` case-insensitive, the same rule as the pipeline. A key ending in a non-word character (a language name with a trailing `+`, for instance) cannot match in prose; FEAT13 pinned that limitation on the line path on purpose (`ClarifyTests.test_wording_ending_in_punctuation_matches_nothing_here_or_in_the_pipeline`), but the rule path still writes such a key to `glossary.toml`, where it fires on nothing.

**The saved key is not what the user sees.** `trimPunctuation` strips leading and trailing punctuation from the heard side (pinned by `test_outer_punctuation_is_trimmed_off_the_heard_side`), and the key is then folded to lower case at match time. The sheet shows the user's raw field only; nothing tells them the key that will be stored or how many lines it would touch. `ClarifyTarget` carries the one line being clarified and nothing else, so no surface today can preview a rule against the meeting.

**Correction at filing: case-only pairs are not a defect in themselves.** FEAT12 deliberately keeps a whole-edit capitalisation fix as a real pair: `VocabularyCandidate.derive`'s doc says a pure capitalisation fix "is a real substitution, since the key is folded and the value is not", and `VocabularyCandidateTests` pins a lower-case product name becoming its capitalised spelling. Refusing every case-only pair, as the audit's direction allows, would break that intended use. The defect is a case-only pair on a common word, and the absence of any preview that would show its reach.

**Correction at filing: FEAT12's offer sheet has the same gap, and fewer checks.** `VocabularyOfferSheet` (a file-private struct in `TranscriptTab.swift`) writes through the same `addVocabularyTerm` into `GlossaryStore.addTerm`. Its fields are editable, its Add is enabled on `!heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !canonical.isEmpty` only, and it neither trims outer punctuation nor refuses identical sides. `VocabularyCandidate.derive` itself can produce a case-only pair on a common word when that is the whole edit.

**Field evidence.** The [2026-11-13 field evidence](../../audits/2026-11-13-field-evidence.md) lists G016 under "Cannot tell from this data", and reports no naming or correction events in the window, so no rule of this kind has been observed being written.

Related: FEAT11, FEAT12, FEAT13 and UX66 (done, [q6-final.md](../q6-final.md)); [ASR5](./ASR5.md) would feed glossary terms into vocabulary boosting, where a common-word key would bias recognition as well as rewrite text.

## Scope

1. **One pure check, in `Clarify.swift`.** `Clarify.ruleCheck(heard:canonical:lines:) -> RuleCheck`, returning the key exactly as `glossary.toml` will store it (after `trimPunctuation`), the number of `lines` it matches by `containsTerm`, and either a refusal reason or a list of warnings. Refusals: a key with no word character at its first or last position (it can never match `\b...\b`); a single-token key that is an English stop-word, folded, from a short fixed list kept beside the check (pronouns, articles, auxiliaries, common prepositions and conjunctions; English only, documented as such). Warnings: a case-only pair (folded equal); a key of one or two characters.
2. **Clarify sheet.** `Clarify.plan` returns nil on `.everyMeeting` when `ruleCheck` refuses, so the disabled button and the refusal stay one rule (the sheet's existing doc comment says exactly this). `ClarifySheet` shows, on the rule path only, the stored key, the match count over this meeting ("matches N lines in this meeting"), each warning in plain language, and the refusal reason when the button is disabled, in the same muted caption style as `lineHint`.
3. **Offer sheet.** `VocabularyOfferSheet` runs the same check: Add is disabled on a refusal and on identical sides, and it shows the same key, count and warnings. It writes the trimmed key, as Clarify does.
4. **The preview seam.** `ClarifyTarget` and `VocabularyOffer` gain the meeting's displayed lines (corrections already overlaid), filled in `TranscriptTab` where each is built (`clarifyTarget = ClarifyTarget(` and `VocabularyOffer.make`). The count is over this meeting only; it is a preview of reach, not a library scan.
5. **Event.** `correction` `vocabulary_term_added` gains `matches_here` (the count) and `case_only` (bool), beside its existing length-only attributes; the words themselves stay verbose-only per SEC14.
6. **Copy.** [docs/GUIDE.md](../../GUIDE.md)'s Clarify bullets (**Always fix this**) say the sheet shows the saved form and how many lines in this meeting it would change, and that common words are refused.

## Explicitly not

- No blanket refusal of case-only pairs: FEAT12's capitalisation fix is intended and pinned (see Correction at filing).
- Not the Preferences Vocabulary editor (`VocabularyEditor`) or hand-edits to `glossary.toml`: deliberate table editing, outside the correction flow; a later task can reuse `ruleCheck` there if the owner wants it.
- Not changing the matching rule (`\b(<key>)\b`, case-insensitive) on either side: FEAT13 pinned that the line path and the rule path share it, and UX66's overlay carry depends on `containsTerm` meaning exactly that.
- Not a library-wide preview (counting matches across every transcript): a scan per keystroke is out of proportion here.
- Not other languages' stop-words.

## Acceptance

- `ClarifyTests`: a single-token stop-word heard side (a pronoun to an acronym) returns nil on `.everyMeeting` and `ruleCheck` names the reason; a heard side with no word-character edge returns nil on `.everyMeeting` (the existing line-path pin stays green); a lower-case product name to its capitalised spelling is allowed with a case-only warning and a correct `matches_here` over sample lines; a two-character key is allowed with a short-key warning; `ruleCheck` reports the trimmed key when the heard side carried outer quotes; the existing outer-punctuation and default-scope tests stay green.
- `VocabularyCandidateTests` stay green unchanged, including the capitalisation pin.
- A test for the offer sheet's enablement rule (extracted to a pure helper if needed): identical sides and a refused key disable Add; a capitalisation pair enables it.
- `vocabulary_term_added` carries `matches_here` and `case_only`; `python3 scripts/truth_fences.py` clean (no new category).
- [docs/GUIDE.md](../../GUIDE.md) Clarify recipe updated in the same commit.
- `bash scripts/ci-local.sh` green; the commit body states how many tests were added.
