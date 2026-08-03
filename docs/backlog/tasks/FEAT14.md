# FEAT14: the roster computes who a voice almost was, then discards it

Filed 2026-08-03 by the audit band, from the product-opportunities angle. P3, promote on demand.

## The observation

`RosterStore.match` scores the current speaker against every enrolled person and builds a full ranked list, then returns `None` whenever either gate fails, throwing away both the top candidate and its similarity.

- `pipeline/src/mp/roster.py:113` is `best = max((cosine_similarity(embedding, c) for c in centroids), default=-1.0)`, inside the loop that builds the ranked `scored` list.
- `pipeline/src/mp/roster.py:119-120` discards the ranking on the first gate (`if top_sim < min_similarity: return None`), and `:122` on the second (`if top_sim - runner_up < margin`).
- `pipeline/src/mp/roster.py:28-29` are `MATCH_MIN = 0.65` and `MATCH_MARGIN = 0.07`, with the module header at `:7` stating the intent: "the roster biases to leaving a speaker unknown over pinning a wrong name".

That bias is correct and must survive any change here. The opportunity is that the near-miss is thrown away rather than offered.

## Why the loop is stalled

Measured on the owner's live data 2026-08-03: the roster holds **11 people carrying 1 or 2 samples each**, and the library holds 11 `.speaker_labels.json` overlays against 207 summarized meetings. So naming happens on roughly 5 percent of meetings and the enrolment corpus is barely growing.

The failure loop is self-sustaining: a recurring colleague scores 0.62 against their own centroid, below `MATCH_MIN`, so the strip renders an unnamed cluster. The owner either types the name from memory or, far more often, does nothing, so that person never gains a second enrolment sample and the next meeting scores the same. With 1 to 2 samples per person, centroids stay weak, which keeps scores below the gate.

`ARCHITECTURE.md:485` states the roster's promise as "each enrolled person with their embeddings and sample count, so a named voice is auto-named in later meetings". At 5 percent that promise is mostly unmet, and the cheapest fix is not a better matcher but surfacing the answer the matcher already computed.

## Scope

Return the top candidate and its similarity from `match` alongside the accept-or-decline verdict, carry it into the per-meeting cast data, and offer it on the chip's existing context menu as a suggestion that enrols on one click.

Two hard constraints:

- It stays a **suggestion in a menu**, never a pre-filled name and never an auto-write. With 1 to 2 samples per person a near-miss is often wrong, and a wrong auto-name is worse than silence. That is exactly the trade the two-gate rule was written for, and this change must not weaken the gates themselves.
- It must not present a similarity number to the owner as if it were a confidence. Show the name, not the score.

`VoiceResolutionBar.actions(for:)` already owns what a chip offers on right-click and already gates each action against what the underlying service will accept, so the suggestion belongs there rather than on `VoiceResolution`. UX57, UX58 and UX59 are all touching that surface, so sequence this after them.

## Acceptance

Suite green with new tests. `match` returns the near-miss candidate on a decline, and a test pins that the two gates still decline exactly the cases they decline today, so the honesty rule is unchanged. The chip menu offers the suggestion only when a near-miss exists, and enrolling from it adds a sample. The empty-roster case still says "nobody is enrolled" rather than offering a suggestion, per FEAT11's existing honesty rule.

## Owner walkthrough

Steps tagged [owner] / [session] by who acts.

1. [session] `./scripts/rebuild.sh`, then tell the owner it is ready.
2. [owner] Open a recent meeting with unnamed voices in the cast strip, and right-click one. Pass: if the roster nearly matched somebody, the menu offers that person's name as a suggestion. If it did not, the menu looks as it does today, with no invented guess.
3. [owner] Accept one suggestion you know is correct. Pass: the voice is named and that person gains an enrolment sample.
4. [owner] Say "FEAT14 good to close" or what is wrong.
