---
id: DV7
title: Rename everywhere leaves the person's open actions behind, because action owners are matched against raw summary text the rename never touches
category: Intelligence
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). DV3 (done) promised a roster rename reflects everywhere, but `PeopleRail.derive` matches each action's raw summary `owner` against the roster's new name while `RosterRename.carry` rewrites only speaker-label overlays, so a renamed person keeps their attended meetings and loses every open action and every owner-only meeting; the same label-match break makes Meeting time drop the owner's talk share once the mic-channel speaker is named in-app (G060). Scope: resolve action owners through former names kept on the roster entry, and match talk share on the raw label as well as the display name, with projection tests for both. [Spec](./DV7.md)
---

# DV7: Rename everywhere leaves the person's open actions behind, because action owners are matched against raw summary text the rename never touches

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source: independent audit finding G015 (medium, confirmed, "Claimed fixed, not holding (DV3)") in [2026-11-12-independent-audit.md](../../audits/2026-11-12-independent-audit.md), plus the low G060 folded in below. Re-verified in code at HEAD `3a2da4fc` on 2026-11-13.

**DV3's fix does not hold.** DV3 (done, commit `a106f41f`, 2026-07-24, spec in [q6-final.md](../q6-final.md)) carried the acceptance line "a roster rename reflects everywhere", and its shipping note names the deviation it took to meet it: `mp roster rename` renames only `roster.json`, so the rename now carries into past meetings through the reversible speaker-label overlay (`RosterRename`). `PeopleView`'s doc comment repeats the promise ("so the roster, this rail, Preferences ▸ Pipeline ▸ People, and past transcripts all read the same name"), and [GUIDE.md](../../GUIDE.md)'s People section says the rail shows "the commitments they own" and that "Renaming carries". The carry reaches attendance and never reaches ownership.

**How ownership is matched.** `PeopleRail.derive` takes the Facts projection's `[ActionCluster]` and keeps a cluster when `cluster.instances.contains { normalized($0.owner ?? "") == key }`, where `key` is the roster entry's current name. The `owner` on each instance is the raw string from `<stem>.summary.json`: `Facts.swift` builds `Action(index: i, task: task, owner: a.owner, due: a.due)` and `LibraryProjections` passes it through unchanged. The meeting list also counts ownership: `ownedStems` is built from the same raw-owner match, and `if attended || ownedStems.contains(m.stem)` adds the meeting.

**What the carry rewrites.** `RosterRename.carry(from:to:in:)` touches only `SpeakerLabelStore` overlays, and only for stems whose `PeopleRail.resolvedPeople(attendees:overlay:)` contains the old name. `resolvedPeople` reads the summary's `attendees` and the overlay's values, never action owners. So after a rename: (a) attended meetings still resolve, because the carry wrote `old -> new` into their overlay; (b) every open action still carries the old name in its `owner` string, so `owned` is empty; (c) a meeting the person appears in only as an action owner is skipped by the carry and drops out of their row. Nothing re-matches until each summary is rewritten, and a regenerate is an engine call the owner has to choose per meeting (GUIDE "After you rename anyone").

**Why the overlay alone cannot fix it.** In a meeting where the name was baked into `<stem>.json` at finalize, the carry does leave `overlay.labels[old] = new`, so resolving an owner through that meeting's overlay would recover it. But where the name came from an in-app naming (`THEM-A` named, then renamed), the overlay is keyed on `THEM-A`, not on the old name, and an owner-only meeting has no overlay entry at all. A durable record of the person's former names is the only input that covers all three cases.

**Low folded in, G060 (same root cause, verified at HEAD).** `MeetingStats.talk(segments:overlay:ownerLabel:)` resolves each line with `SpeakerLabelStore.displayLabel(for:using:)` and then tests `key == channelOwnerLabel || (!owner.isEmpty && key == owner)`, where `channelOwnerLabel` is `"speaker_user"`. Once the owner names the mic-channel speaker in the Transcript tab (or a roster rename carries a new name onto it), the resolved label is that name, which is neither `speaker_user` nor `summarization.user_label` unless the two happen to be equal, so the owner's speech counts as `theirsSec` and Meeting time reports the owner's share wrongly or as `not measured`. The raw label that identifies the mic channel is discarded before the comparison.

Related: UX41 (done, [q6-final.md](../q6-final.md), accepted stale names inside summary prose with a re-summarize cue, which is about the prose, not about the rail's matching), [FEAT19](./FEAT19.md) and [FEAT21](./FEAT21.md) (naming flow and owners published as diarization labels, adjacent but separate), [DV5](./DV5.md) (what the Facts rail should become; its measurement found only 36.9% of owned open actions name a human, so the rail already under-reports before any rename).

## Scope

1. **Former names on the roster entry.** `RosterStore.rename` in `pipeline/src/mp/roster.py` appends the old name to a new optional `former_names` list on the entry (deduplicated, normalized the way `PeopleRail.normalized` normalizes, and with the new name removed from the list, so renaming back collapses it). `schema_version` stays 1 since the field is optional and readers ignore unknown keys; `RosterProfile.Person` gains `formerNames: [String]`, read as `[]` when absent. The pipeline stays the roster's only writer (CONVENTIONS "`roster.json`"), so `mp roster rename` is the one seam.
2. **Match ownership on every name the person has carried.** `PeopleRail.derive` builds the owner key set from `entry.name` plus `entry.formerNames` and uses it for both `owned` and `ownedStems`. A former name that is another enrolled person's current name matches only that person (current names win), so a swap or a reuse cannot fold two people into one row.
3. **Attendance through the same set.** `derive`'s `attended` check uses the same key set, so a meeting whose overlay the carry skipped (an unwritable sidecar, `RosterRename.carry`'s logged best-effort failure) still lists the person.
4. **Talk share on the raw label (G060).** In `MeetingStats.talk`, decide "mine" from the row's identity before the overlay as well as after: take the row through `MeetingCast.rowSpeaker(for:overlay:voiceprintLabels:)` (the one sanctioned row-speaker read, per `daemon/CLAUDE.md`) and count the line as the owner's when its `label` is `channelOwnerLabel` or its `label` or `displayName` normalizes to `ownerLabel`. A per-segment reassignment away from the mic speaker keeps winning, because `rowSpeaker` already puts the reassignment ahead of the raw id.

## Explicitly not

- Rewriting `owner` strings inside `<stem>.summary.json`. It is the engine's output, the rename must stay reversible, and an unmodeled write path into summaries is what `daemon/CLAUDE.md`'s summary rule exists to prevent.
- Resolving owners through each meeting's overlay instead of former names: it covers only the baked-name case (Context, last paragraph).
- Matching owners by first token or substring. `PeopleRail.normalized`'s doc records why looser matching folds two different people into one row.
- Owners that are diarization labels (`THEM-A`, bare numbers, `Speaker N`): [FEAT21](./FEAT21.md) and [DV5](./DV5.md).
- A rename UI change. The prompt, `RosterRename.run` and the carry stay as they are.

## Acceptance

- `pipeline/tests/test_roster.py`: rename appends the old name to `former_names`; a second rename keeps both; renaming back to a former name removes it from the list and leaves the entry as it was before the first rename; a colliding rename still returns False and writes nothing; a roster file with no `former_names` loads and renames.
- `RosterProfileTests`: `formerNames` reads from the field and is `[]` when absent or malformed.
- `PeopleRailTests`: a person renamed after owning open actions in three meetings keeps all of them under the new name; a meeting where they appear only as an action owner stays in their meetings list; a former name equal to another enrolled person's current name is credited only to that person; a person with no former names derives exactly as today (the existing tests stay green unchanged).
- `MeetingStatsTests`: a transcript whose `speaker_user` cluster is named in the overlay still counts that speech as mine; a line per-segment reassigned away from `speaker_user` counts as theirs; with `ownerLabel` set and the owner's baked label renamed in the overlay, the speech counts as mine.
- `CONVENTIONS.md`'s `roster.json` line names `former_names` and its meaning in the same commit.
- `cd pipeline && uv run --extra dev pytest -q`, ruff and pyright green; `cd daemon && swift build` and `swift test` green; N new tests named in the commit body; `bash scripts/ci-local.sh` green.
