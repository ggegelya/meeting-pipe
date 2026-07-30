# WF9: Workflow store duplicates (cause, diagnostic, name-collision cue)

Band origin: filed 2026-07-23 (observed during the 2026-07-23 assessment session while reading the owner's live config). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

**WF9 (P3, new): the owner's workflow store holds duplicate rows nothing explains, and name-keyed surfaces mis-scope on collisions.** On 2026-07-23, `~/.config/meeting-pipe/workflows/` held 8 TOMLs: four named "Client work" (distinct ids, orders 3, 5, 7, 8; one `is_default = true`; all `nda_mode = true`, filesystem-only sinks), two named "Personal", one "Untitled workflow", one "General". Every one has `matching_rules = []`, so the duplicates change nothing about routing (precedence falls through to the default), but they clutter the Workflows tab and the prompt chevron, and the Library WORKFLOWS rail resolves scope by workflow NAME (the WF8 ship note records "scope resolves by workflow name"), so four same-named workflows collapse into one scope whose counts and membership are not explainable from the UI. Two adjacent facts recorded for the owner, decisions not code: the effective default workflow is an NDA "Client work", meaning every unmatched meeting summarizes local with filesystem-only sinks (if unintended, flip the default in the Workflows tab); and the "Untitled workflow" row is presumably abandoned scaffolding to delete by hand.

Cause is unknown; that is the first deliverable. Candidate mechanisms to test, in order: the WorkflowsView editor's save path (it clones state on save, WorkflowsView.swift:588, 623; does an edit-save loop ever create instead of update?), `WorkflowMigrator` re-seeding (does the first-run shim re-run and re-create under some condition, e.g. a missing marker or a config reset?), and plain repeated manual creation (the duplicates' `order` values 3, 5, 7, 8 interleave with other rows, which weakly suggests creation events over time rather than one bug burst). Reproduce or rule out each with evidence; if a bug is found, fix it at the store/editor seam with a regression test.

Scope beyond the cause: (a) a load-time diagnostic in `WorkflowStore` that logs one event when duplicate names are present (existing daemon event category, no new category); (b) a quiet name-collision cue in the Workflows tab (a small badge or hint row, PRODUCT.md register, no modal); (c) nothing auto-deletes: cleanup of the existing debris is the owner's, by hand, in the UI, because deleting a workflow is destructive and the duplicates may differ in fields the owner wants to compare first.

Explicitly not: no unique-name constraint (renaming a workflow is common and a hard block on save is hostile; the cue in (b) is the register); no change to name-keyed scope resolution itself (moving scopes to id-keyed is a bigger WF change; note it in the ship if the collision cue proves insufficient); no migration that rewrites the owner's files.

Acceptance: the duplication cause is named with a repro test or each candidate mechanism is ruled out with evidence recorded in this file; the duplicate-name event and the collision cue are pinned by tests (store fixture with two same-named workflows); `WorkflowStore` round-trip suite stays green; owner-owed: manual cleanup of the four "Client work" rows and the default-workflow decision, after the cause is known (cleaning up first would destroy the repro).

## Cause hunt, 2026-07-28

**Found. It is the onboarding workflow step, not the editor.** Two independent leaks in `OnboardingStepWorkflow.choose`, both closed by reusing the created row's id so a preset swap is an update:

1. **Re-picking a preset within the step.** `choose` deleted the workflow it had created before creating the replacement. Every preset is created `isDefault: true`, and `WorkflowStore.delete` refuses to remove the default and returns `false`, which `_ = try? …` threw away. So the delete silently no-opped and the replacement was appended beside its predecessor, once per re-pick.
2. **Leaving and re-entering the step.** `OnboardingRootView` is a `switch step`, so Back / Continue destroys and rebuilds the step. `createdID` lived in the step's own `@State`, so it died on each round trip and the next pick did not even attempt a delete.

Evidence that this is what happened, from the owner's live store (read, never modified):

| order | name | color | backend | default | reading |
|---|---|---|---|---|---|
| 0 | General | `#3478F6` | anthropic | no | migrator seed: notion sink carrying the real `notion.database_id`, and the blue is the pre-DSN11 `defaultWorkflowHex` |
| 1 | Untitled workflow | `#3478F6` | anthropic | no | the `NewWorkflowSheet` stub, field for field: name, colour, `backend: .anthropic`, and a notion sink with an **empty** `database_id`. Opened, never named, never cancelled |
| 2 | Personal | `#FF6074` | anthropic | no | off-palette, so hand-picked through the old free-hex `ColorPicker` DSN11 removed. Manual creation |
| 3, 5, 7, 8 | Client work | `#B27300` | local | order 8 only | onboarding's Client preset, post-DSN11 (amber is `workflowSwatches[5]`) |
| 6 | Personal | `#0E9488` | anthropic | no | onboarding's Personal preset, post-DSN11 (teal is `workflowSwatches[0]`) |

Order 4 is absent, which is the one delete that worked: a non-default row, so the guard let it go. The 3 / 5 / 6 / 7 / 8 interleave is alternating picks, and the newest being the default is `upsert`'s single-default invariant.

The negative check is the proof: reverting `presetWorkflow` to mint a fresh id and re-running `OnboardingWorkflowPresetTests` produces `["Client work", "Client work", "General", "Personal", "Personal"]` from four alternating picks, the owner's shape in miniature.

Candidates as the task filed them:

- **WorkflowsView editor save path (`:588`, `:623`) - ruled out.** `save()` clones `workflow`, whose `id` is a `let`, and `upsert` matches on `id`, so an edit-save loop is an update by construction. It cannot create. `test_upsert_enforces_single_default` and the round-trip suite already pin it.
- **`WorkflowMigrator` re-seeding - ruled out.** `runIfNeeded` returns early on `guard store.workflows.isEmpty`, and the store has held rows continuously since order 0. The live store holds exactly one "General", which is one seed. `WorkflowMigratorTests` pins the idempotence.
- **Plain repeated manual creation - partly true, and it is a third bug.** Order 1 is `NewWorkflowSheet`'s stub, which is persisted on open so the rail can route to the new scope, and removed only by Cancel or kept by Save. Its Cancel calls the same `delete` that refuses the default, so on an empty store (`isDefault: store.workflows.isEmpty`) a cancelled New workflow cannot be removed at all. Order 2 is genuine manual creation, later hand-recoloured.

**Shipped in this task:** the two onboarding leaks fixed with `OnboardingWorkflowPresetTests` as the regression; a `workflow.duplicate_names` event on `WorkflowStore.load()` (existing category); the quiet cue in both places a collision is visible (the rail row's `· duplicate name` caption with an explaining tooltip, and a hint row under the editor's Name field). No unique-name constraint, no change to name-keyed scope resolution, no migration, nothing auto-deleted.

**Still owner-owed:** the four "Client work" rows, the "Untitled workflow" stub, and the duplicate "Personal" are all still on disk, by design. Deleting a workflow is destructive and the duplicates differ in fields worth comparing first. The default is still an NDA "Client work", so every unmatched meeting summarizes on-device with filesystem-only sinks; flip it in the workflow editor's Default toggle if that is not intended. The rail now says which rows collide, which is the surface to do the cleanup from.

**Not done, and worth naming:** `NewWorkflowSheet`'s stub-on-open is the same "delete may refuse" shape as leak 1 and can still orphan a row on an empty store. It is out of WF9's scope (its own surface, its own decision about whether a stub should be persisted before the first save at all) and is unreachable while the migrator guarantees a default exists. If the collision cue proves insufficient, the bigger move behind it is switching scope resolution from name-keyed to id-keyed, which is a WF-band change touching the sidecar contract, not this task.

## Owner walkthrough (for the session that picks this up)

Added 2026-07-30 at the owner's request: every task gated on an owner action carries one. Walk the owner through it step by step; the owner does not read code. Steps are tagged [owner] / [session] by who acts.

1. [session] Verify the state on disk first, because as of 2026-07-30 both owner-owed items appear already done: `~/.config/meeting-pipe/workflows/` holds exactly three rows (Client work, General, Personal), no duplicates, no "Untitled workflow" stub, and the default decision is taken (Personal carries `is_default = true`, so the NDA Client work is no longer the silent default for unmatched meetings).
2. [owner] Confirm that matches intent, in the app: the rail shows three workflows with no `· duplicate name` caption anywhere, and you are happy that unmatched meetings default to Personal (cloud-capable) rather than the NDA clamp.
3. Confirmed: [session] moves WF9 to done per the archive process. If the rail still shows a duplicate caption after a rebuild, the UI disagrees with the store on disk; that is a new finding to file, not a WF9 reopen.
