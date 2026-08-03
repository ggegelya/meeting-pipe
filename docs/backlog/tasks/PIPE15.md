# PIPE15: the Anthropic summarize path has no shared coercion and its one retry is blind

Filed 2026-08-03 by the audit band. Proposed high, downgraded to medium by an independent skeptic on measured impact.

## What is wrong

`AnthropicSummaryClient.summarize` validates the tool payload directly with no coercion for a section that arrived as a JSON-encoded string instead of a list, and its single retry re-issues a byte-identical request with no error feedback, so the same malformed reply can recur and the run dies.

- `pipeline/src/mp/summarize.py:399` is `return MeetingSummary.model_validate(tool_blocks[0].input)`, sending raw tool input straight to pydantic. The shared recovery helper `json_extract.parse_summary` is never used on this path.
- `pipeline/src/mp/summarize.py:366-406` builds an identical `messages` payload on both attempts, with no ValidationError replayed to the model, and `:406` is `raise last_err`.
- `pipeline/src/mp/schemas.py:150-160` shows `normalize_model_summary` returning the payload untouched unless a section is a list containing dicts, so a `str` section passes through unrepaired to the strict `list[str]` field at `schemas.py:187`.

Reproduced against today's tree on 2026-08-03: `MeetingSummary.model_validate({"summary": json.dumps(["a","b"]), ...})` still raises `list_type`, including when `decisions` arrives in the post-FEAT10 object shape so `normalize_model_summary` actually executes.

The local backend has three recovery layers plus `summarize_local.repair_messages`, which replays the pydantic error to the model. The cloud path, which is the shipped default (`config.py:122`), has neither.

## Measured impact, stated honestly

It has fired three times on the owner's real corpus: `pipeline.log:472` (2026-05-22, `summary`), `:1195` (2026-06-10, `questions`), and `:2925` (2026-07-20, `summary`). Two of the three recovered only because the blind attempt-2 re-roll happened to come back well-formed, at the cost of a second paid model call.

One killed a run: `20260720-130337.error.json` exists with no sibling `.summary.json`. The skeptic checked what that meeting was and it is a 78-second non-meeting whose entire transcript is the word "Who". So **no meeting content has been lost to this**, and the failed row keeps a working Retry. That is why it is medium rather than high. The mechanism is real, the wasted paid call is real, and the next occurrence could land on a real meeting.

## Scope

Add a coercion to `normalize_model_summary`, which is the file's own designated home for a transform every backend must share: when a section or `attendees` arrives as a string that `json.loads` to a list, use the decoded list. Leave everything else untouched so the normalizer stays idempotent on the stored shape.

Separately, make the Anthropic attempt-2 replay carry the ValidationError back to the model the way `summarize_local.repair_messages` does, instead of re-issuing an identical request. That is the cheaper half and it fixes the whole class rather than one shape.

Fix `summarize.py`'s module docstring, which still describes a recovery ladder this path does not have.

## Acceptance

Suite green with new tests. A schemas test pins a stringified section round-tripping to a list. A summarize test pins that attempt 2 differs from attempt 1 and carries the validation error. No owner walkthrough: the trigger is a model behaviour the owner cannot summon on demand.
