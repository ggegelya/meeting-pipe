---
id: DOC19
title: Accepted ADRs and the user guides describe behaviour the code has left behind, with no amendment
category: Docs
status: new
priority: P2
comment: Filed 2026-11-13 (audit band 2026-11-13). Five accepted ADRs (0003 FTS5 absent, 0004 rejected the activation-policy flip the app now does, 0007 daemon-stays-offline vs NotionDatabaseList, 0008 one AX walk per meeting, 0016 whole-file 85% guard) state superseded behaviour with no dated note, and GUIDE and SETUP name three controls the code does not have (Manage Workflows opens the Library, not the editor; Preferences has no Verify connection; the Finish setup row has no Download now). Dated amendment per ADR, recipes corrected, one docs-only commit.
---

# DOC19: Accepted ADRs and the user guides describe behaviour the code has left behind, with no amendment

Band origin: filed 2026-11-13 (audit band 2026-11-13, see [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md)). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

## Context

Source findings: F200 and G058 (architecture lens) and G057 (quality lens) in the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md), all three in its "Low findings, not verified" table with no claim text beyond the title. Every item below was re-verified in code at HEAD on 2026-11-13; what did not hold, or could not be located, is said in the correction lines.

**ADRs.** An accepted ADR is what a session reads when the question is "why is it shaped this way" (root `CLAUDE.md` routes it to [docs/decisions/](../../decisions/)), so an ADR that states an invariant the code dropped sends that session to defend or rebuild something already gone. ADR 0016 carries a dated amendment and ADR 0008 a superseding note, so the repo has the pattern; these five lack it for the changes below.

1. [ADR 0003](../../decisions/0003-filesystem-library-source-of-truth.md) (Accepted) says in Consequences that TECH-A2 "was reframed during implementation; the FTS5 backend is not present in the codebase", with "quick-find takes longer than 200 ms" as the revisit trigger. At HEAD `SearchIndex.swift` is a "SQLite FTS5 index over the library's searchable text + full transcripts (UX16)", populated by `SearchIndexer` and read by `QuickFindRanker`'s `ftsMatches`, `SavedSearch` and the Library filter bar. The ADR's decision (the filesystem is the source of truth, the index is rebuildable) still holds; the FTS5 sentence does not.
2. [ADR 0004](../../decisions/0004-menu-bar-over-dock-app.md) (Accepted) rejects Option C, the hybrid that shows a Dock icon while a window is open, because "the implementation has to track every open window and flip the policy at the right moment". `WindowActivationManager` is exactly that: it "Toggles `NSApp.activationPolicy` between `.accessory` (no Dock icon) and `.regular` (Dock + Cmd+Tab) according to which windows are open", called from `LibraryWindow.show()`, `PreferencesWindow.show()`, `DiagnosticsWindow.show()` and `GuideWindow.show()` (UX39, UX48, UX56). The shipped app is Option C; the ADR still records B as the decision.
3. [ADR 0007](../../decisions/0007-python-sidecar.md) (Accepted) cites the "Daemon-stays-offline rule" ("Outbound HTTP belongs in the pipeline"), and its own PROV1 amendment re-asserts that PROV1 "does not overturn the daemon-stays-offline rule". `NotionDatabaseList` calls `https://api.notion.com/v1/search` and `https://api.notion.com/v1/databases/<id>` over `URLSession` from the daemon (the Preferences and Welcome database picker). [HYG10](./HYG10.md) already found the same contradiction in `daemon/CLAUDE.md` and `CONVENTIONS.md` and holds the owner's call on the rule (its scope item 3: amend the rule to name the picker, or move the picker behind `mp`).
4. [ADR 0008](../../decisions/0008-verdict-fusion-architecture.md) (Accepted, mic-gating disposition superseded by 0016) states "The AX-tree walk happens once per meeting ... This is the load-bearing shared-infrastructure invariant." At HEAD `MeetingAXHandleBuilder` injects two fresh-walk resolvers, `resolveMute` (TECH-MIC6) and `resolveLeave` (TECH-END2), and both are called mid-meeting: `AXMuteButtonProbe.noteUnknownAndMaybeRearm` re-walks once per `rearmThreshold` unknown polls, and `AXLeaveButtonSignal` keeps its `resolveElement` "re-walk across the re-arm". HYG10's 2026-10-25 amendment already lists `MeetingAXHandleBuilder`'s "walked once at start" doc comment as false; this task owns the ADR half.
5. [ADR 0016](../../decisions/0016-capture-first-mute-redaction.md)'s 2026-06-08 amendment specifies the runaway guard as whole-file: redaction is withheld "when the muted spans cover at least 85% of the recording AND the mic channel carries sustained energy". `MuteRedactor` replaced it: "Per-span runaway guard (TECH-MIC12, replacing the whole-file 85%-coverage cliff of TECH-MIC9)", which redacts only quiet spans and withholds speech-bearing ones, and MIC14 exempts manual off-the-record spans from the withhold. The ADR mentions neither MIC12 nor MIC14.

**User guides.** [docs/GUIDE.md](../../GUIDE.md) and [docs/SETUP.md](../../SETUP.md) carry the same-commit contract in root `CLAUDE.md` ("a recipe naming a control that no longer exists is a filing-quality failure, not a cosmetic one"), and GUIDE renders in-app from the menu bar's **Guide…**.

6. GUIDE "Making and editing one" says "The menu bar's **Manage Workflows…** is the same editor without opening the Library first." `Coordinator.menuManageWorkflows` only calls `libraryWindow.show()`, and its doc comment says it "Deliberately does NOT auto-open the New sheet, which persists an orphan 'Untitled workflow' stub if closed without naming" (TECH-WF5). The row opens the Library, not the editor.
7. SETUP Step 6 introduces three numbered steps as working "In the Welcome window's **Where summaries go** step, or later in **Preferences ▸ Integrations**", and step 3 is "Click **Verify connection**". `Button("Verify connection")` exists only in `OnboardingStepPublishTarget`; the Preferences Notion group (`PreferencesView+Integrations`) has the token field, `NotionDatabasePicker`, the transcript toggle and a Configured / Not configured status pill, and no verify button.
8. SETUP Step 7 says the Welcome flow's workflow step, the workflow editor "and the menu bar's **Finish setup** row all offer a **Download now** button". The first two do (`OnboardingStepWorkflow`, `WorkflowsView`); the Finish setup checklist's item is `SetupChecklist.Item.localModel`, titled "Download the on-device model", which runs `.downloadModel`. Same action, different control name, so a reader looking for "Download now" under Finish setup does not find it.

Correction at filing: G057's audit row names three controls but gives no detail. Item 6 is the one its location (`docs/GUIDE.md`, the workflow recipe) points at; items 7 and 8 were found by walking SETUP Steps 6 and 7 against the code on 2026-11-13 and may not be the two the finder meant. The pickup re-walks every control named in those two steps and in GUIDE's workflow section before closing.

Correction at filing: F200's title also says "scope docs", and nothing in the audit names which. No scope-doc target is invented here; the five ADRs above are what verified.

## Scope

One docs-only commit, no code change.

1. Append a dated `## Amendment <pickup date> (DOC19): ...` section (or, for 0008, extend its existing superseding note) to ADRs 0003, 0004, 0008 and 0016, each naming the task or tasks that changed the behaviour (UX16; UX39, UX48, UX56; TECH-MIC6, TECH-END2; TECH-MIC12, MIC14), what the code does now by symbol, and whether the decision itself still stands. Update each ADR's `Status` row to say amended, with the date. 0003's decision stands with the FTS5 sentence corrected; 0004's decision is now Option C in practice, so the amendment says so plainly rather than softening it; 0008's shared-infrastructure point stands as "one resolution at start, re-resolved on staleness".
2. ADR 0007: append the amendment only after HYG10's owner call on the Notion rule, recording whichever way it went (the picker named as a sanctioned daemon HTTP call beside FluidAudio's model fetch, or the picker moved behind `mp`). If HYG10 is still open at pickup, write the amendment as "the daemon makes one class of outbound call, the Notion database picker; the rule's status is decided in HYG10" and link it.
3. GUIDE: change the Manage Workflows sentence to what the row does (opens the Library with the WORKFLOWS rail, from which **+ New workflow** or a row's **Edit workflow…** opens the editor).
4. SETUP Step 6: say **Verify connection** is in the Welcome step only, and what Preferences shows instead (the Configured status pill, and **Run doctor…** for a real check).
5. SETUP Step 7: name the Finish setup row's item as it reads ("Download the on-device model").

## Explicitly not

- Deciding the daemon-stays-offline rule. HYG10 owns that owner call; this task records its outcome in ADR 0007.
- The `MeetingAXHandleBuilder` doc comment and the `daemon/CLAUDE.md` / `CONVENTIONS.md` copies of the offline rule: HYG10.
- Changing any behaviour to match an ADR (making Manage Workflows open the editor, adding Verify connection to Preferences). Each is a UX change with its own tradeoff (TECH-WF5 rejected the first on purpose); file separately if wanted.
- The README, SETUP and CONVENTIONS privacy and contract claims (muted spans redacted by default, only the summarizer sees the transcript, every cross-tree surface fixture-pinned): [DOC20](./DOC20.md).
- ADR 0016's regulated-gate clause, which [MIC18](./MIC18.md) may reverse; if MIC18 lands first, its own amendment and this one go in the same ADR one after the other.
- GUIDE presentation: [DOC13](./DOC13.md). Process-doc weight: [DOC17](./DOC17.md).

## Acceptance

- ADRs 0003, 0004, 0008 and 0016 each carry an amendment dated at pickup naming the superseding task and the current symbol, and their `Status` rows say amended. ADR 0007 carries one consistent with HYG10's state at pickup.
- The original ADR text is left as written (an ADR is a record of what was decided then); each superseded sentence named in Context (0003's "the FTS5 backend is not present", 0004's Option B decision, 0008's "once per meeting", 0016's "85% of the recording") is answered by its amendment, which a reader reaches by reading on in the same file.
- GUIDE's workflow recipe and SETUP Steps 6 and 7 name only controls that exist where they say: each named label greps to a `Button`, `SettingsGroup`, menu item or checklist title in `daemon/Sources` at the stated location. The pickup lists in the commit body every control it walked in those sections.
- `daemon/Tests/MeetingPipeTests/GuideDocumentTests.swift` stays green (it parses the shipped GUIDE and checks its recipe areas); `python3 scripts/truth_fences.py both` green (dead links, run-on entries); `bash scripts/ci-local.sh fences` green; no U+2014 on changed lines.
