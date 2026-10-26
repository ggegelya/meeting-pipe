---
id: FEAT14
title: The roster computes who a voice almost was, then discards it
category: Feature
status: partial
priority: P3
comment: Shipped 2026-08-18, owner-promoted out of P3 for this batch. **The `partial` is the owner-verification gate alone; no dev remainder is owed.** `RosterStore.match_detail` returns the two-gate verdict **plus** the near miss behind a decline, `match` is the verdict-only reader over it (so no caller that wants a name can act on a suggestion by accident), and `resolve_speaker_labels` returns `(mapping, near_misses)` keyed by the final `THEM-x` label, which finalize writes into `<stem>.embeddings.json` as `near_misses` (schema 2, written only when there is one). Swift reads it through `MeetingStore.nearMisses`, `VoiceResolution.derive` hangs it on `Voice.suggestedName`, and `VoiceResolutionBar.actions(for:)` offers `Name as <person>` as a second item under `Name this voice...` on an unresolved chip, one click into the same `nameSpeaker` enroll the naming sheet runs, so accepting adds the enrolment sample the stalled loop was never getting. **Both gates are untouched and pinned**: `MATCH_MIN` 0.65 and `MATCH_MARGIN` 0.07 are asserted as values and both decline shapes re-asserted, so the suggestion is bought with a floor of its own (`SUGGEST_MIN` 0.50) rather than by lowering the accept bar. **No similarity crosses into Swift at all**, so no surface can render a cosine as a confidence; the item spells the name and carries "not a certain match" under it instead. Three decisions the spec left open: the margin gate gates the suggestion too (a top candidate the runner-up is level with is a coin flip between two real people, so it suggests neither), a suggestion whose person is no longer enrolled is dropped (which subsumes FEAT11's empty-roster rule rather than special-casing it), and accepting emits `coordinator.roster_suggestion_accepted` so "did surfacing near misses actually grow the corpus" is answerable from the log rather than from guessing at sample counts. Verified: `pytest -q` 1268 passed 1 skipped (13 new), ruff clean, `swift build` clean, `swift test` 2615 tests 0 failures (10 new, 2605 on the base), `truth_fences.py both` clean. Pyright 0 errors, but only as `uv run --extra dev --extra mcp pyright`: the command `pipeline/CLAUDE.md` lists in its Build + test block, `uv run --extra dev pyright`, now reports 3 unresolved `mcp.*` imports in AUTO3's `mcp_serve.py`, because CI's typecheck job installs `mcp>=1.29,<2` and that local command does not. A doc-truth gap in the local command rather than a code defect, and not FEAT14's to fix. **Fixed by `46e9d28` the same day**, which changed that block to `uv run --extra dev --extra mcp pyright` and added a note explaining why the extra is load-bearing; the finding above stands as the dated observation it was (HYG8, 2026-08-19). Docs: README's Transcript-tab paragraph, `docs/GUIDE.md`'s cast-strip recipe, ARCHITECTURE's FEAT11 bullet and both sidecar rows, CONVENTIONS' embeddings + roster sections, the design kit's known-lag note. **The remainder, and the only thing owed, is a read-only probe**: over the existing `<stem>.embeddings.json` corpus plus `roster.json`, recomputing `match_detail` per unnamed label to count how many of the 207 summarized meetings would have offered a suggestion. Filed separately as [`FEAT17`](./FEAT17.md) rather than built here. It exists because the filed walkthrough could not have passed at all (no meeting on disk carries `near_misses`, since only `mp finalize` writes one) and because the rewritten one, around a Re-transcribe, still passes whether or not a near miss exists, so no owner check can tell "works" from "never fires on this library" while the probe answers exactly that for free and for no owner time. Owner took that route 2026-08-18 over spending a re-transcribe. The row stays here rather than moving to [`owner-verification.md`](../owner-verification.md): what was approved is the probe, not an owner-verification weight, and none is recorded. [`tasks/FEAT14.md`](./FEAT14.md) carries both, the probe as the next step and the in-app check recorded under it.
---

# FEAT14: the roster computes who a voice almost was, then discards it

Filed 2026-08-03 by the audit band, from the product-opportunities angle. P3, promote on demand; promoted by the owner 2026-08-18 and shipped that day. Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## The observation

`RosterStore.match` scored the current speaker against every enrolled person and built a full ranked list, then returned `None` whenever either gate failed, throwing away both the top candidate and its similarity.

Cited by symbol rather than line, per the filing preference HYG6 recorded (line numbers drift; these already had):

- inside the loop that builds the ranked `scored` list: `best = max((cosine_similarity(embedding, c) for c in centroids), default=-1.0)`.
- the first gate discarded the ranking with `if top_sim < min_similarity: return None`, and the second with `if top_sim - runner_up < margin: return None`.
- the constants are `MATCH_MIN = 0.65` and `MATCH_MARGIN = 0.07`, with the module header of `pipeline/src/mp/roster.py` stating the intent: "the roster biases to leaving a speaker unknown over pinning a wrong name".

That bias is correct and must survive any change here. The opportunity is that the near-miss is thrown away rather than offered.

## Why the loop is stalled

Measured on the owner's live data 2026-08-03: the roster holds **11 people carrying 1 or 2 samples each**, and the library holds 11 `.speaker_labels.json` overlays against 207 summarized meetings. So naming happens on roughly 5 percent of meetings and the enrolment corpus is barely growing.

The failure loop is self-sustaining: a recurring colleague scores 0.62 against their own centroid, below `MATCH_MIN`, so the strip renders an unnamed cluster. The owner either types the name from memory or, far more often, does nothing, so that person never gains a second enrolment sample and the next meeting scores the same. With 1 to 2 samples per person, centroids stay weak, which keeps scores below the gate.

`ARCHITECTURE.md`'s `roster.json` row states the roster's promise as "each enrolled person with their embeddings and sample count, so a named voice is auto-named in later meetings". At 5 percent that promise is mostly unmet, and the cheapest fix is not a better matcher but surfacing the answer the matcher already computed.

## Scope

Return the top candidate and its similarity from `match` alongside the accept-or-decline verdict, carry it into the per-meeting cast data, and offer it on the chip's existing context menu as a suggestion that enrols on one click.

Two hard constraints:

- It stays a **suggestion in a menu**, never a pre-filled name and never an auto-write. With 1 to 2 samples per person a near-miss is often wrong, and a wrong auto-name is worse than silence. That is exactly the trade the two-gate rule was written for, and this change must not weaken the gates themselves.
- It must not present a similarity number to the owner as if it were a confidence. Show the name, not the score.

`VoiceResolutionBar.actions(for:)` already owns what a chip offers on right-click and already gates each action against what the underlying service will accept, so the suggestion belongs there rather than on `VoiceResolution`. UX57, UX58 and UX59 are all touching that surface, so sequence this after them (all three closed 2026-08-04).

## Acceptance

Suite green with new tests. `match` returns the near-miss candidate on a decline, and a test pins that the two gates still decline exactly the cases they decline today, so the honesty rule is unchanged. The chip menu offers the suggestion only when a near-miss exists, and enrolling from it adds a sample. The empty-roster case still says "nobody is enrolled" rather than offering a suggestion, per FEAT11's existing honesty rule.

## Decisions worth not simplifying away

Two of them are load-bearing and read as arbitrary from the outside, which is how they get "simplified" back out.

**The margin gate gates the suggestion too, not just the name.** A near miss is offered only when the *sole* thing standing in the way was the similarity floor. When the runner-up is level with the top candidate, the decline is a coin flip between two real enrolled people, and putting one of those two names in front of the owner is precisely the wrong-name outcome the margin gate exists to prevent. Routing a suggestion around it would reintroduce that outcome through the menu, one confirmation click later. So an ambiguous pair suggests **neither**.

**`SUGGEST_MIN = 0.50` is a floor of its own, not a lowered `MATCH_MIN`.** Every roster has a nearest person to any voice, so with no floor at all the app would offer a name for every unknown speaker it ever hears. A suggestion that is usually wrong teaches the owner to ignore the one that is right, which costs more than the feature earns. It sits below `MATCH_MIN` deliberately: the band this task exists to surface is the one the accept rule refuses. Neither gate constant moved, and a test asserts their values so a future edit to either has to be deliberate.

## What is owed next: the probe, not an owner walkthrough

**Owner decision 2026-08-18: build the probe first, and do not spend the re-transcribe.**

A read-only probe over the existing `<stem>.embeddings.json` corpus plus `roster.json`, recomputing `match_detail` for every unnamed label and counting how many of the 207 summarized meetings would have offered a suggestion, and to whom. No re-transcribe, no UI, no owner time. Filed separately as [FEAT17](FEAT17.md) (`/spike` shaped, with its verdict thresholds pre-registered), not part of this task.

It comes first because **no owner check can answer the question it answers.** The walkthrough below passes whether or not a near miss exists in the owner's data, by design, since "no invented guess" is a correct outcome. That makes it unable to distinguish "this works" from "this never fires on this library", and the second is a live possibility: 11 people at 1 or 2 samples each is exactly the regime where scores may sit below `SUGGEST_MIN` rather than in the band between the two floors. Spending a re-transcribe to learn nothing about that is the wrong order.

## An in-app check, recorded but not the next step

Kept because it is what an eyeball on this feature looks like once the probe says there is something to see. Steps tagged [owner] / [session] by who acts.

The filed version of this walkthrough (open a recent meeting, right-click, look) could not have passed: the suggestion is written when a meeting is **finalized**, so no meeting already on disk carries one. Seeing one costs a re-transcribe of one meeting, which runs entirely on this Mac and takes a few minutes.

1. [owner] `./scripts/rebuild.sh` from the repo root, which rebuilds and relaunches the app. Not a [session] step: a worktree session must not rebuild over the running app.
2. [owner] Open a meeting whose cast strip shows an unnamed voice you can recognise by listening, and right-click that chip. The chips read **Unknown A**, **Unknown B** and so on; `THEM-A` is the on-disk label and never appears in the strip. Expect only **Name this voice...**, exactly as before. That is the before-state, not a failure: this meeting was finalized before the suggestion existed.
3. [owner] Re-transcribe that meeting: the detail pane's `...` menu, **Re-transcribe...**. Nothing is published, the summary is kept, and the names you have already applied are carried.
4. [owner] Reopen its Transcript tab and right-click the same unnamed chip. **Pass** either way, and which one you get is the finding: if the roster came close to somebody, the menu now carries a second item, **Name as \<person\>**, with a line under it saying it is not a certain match. If it came close to nobody, the menu is exactly as it was in step 2, with no invented guess.
5. [owner] Only if you recognise the suggested name as correct, click it. Pass: the chip takes that name, its icon stops being the unnamed marker, and in **Preferences ▸ Pipeline ▸ People** that person's sample count is one higher than before. If the suggestion is wrong, do not click it, and use **Name this voice...** instead; nothing was written by the item merely appearing.
6. [owner] Say "FEAT14 good to close" or what is wrong.
