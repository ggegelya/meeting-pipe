# SEC21: NDA workflow classification fails open: a meeting whose title is not known yet, or whose rule regex does not compile, silently falls through to the default (non-NDA) workflow, and turning NDA on later does not cover past meetings

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) S7). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Latent on the owner's Mac: all three workflows in `~/.config/meeting-pipe/workflows/` have `nda_mode = false` (checked 2026-10-24). It bites the first time anyone relies on an NDA workflow to catch a meeting by title.

`WorkflowMatcher.resolve` (pure, in `daemon/Sources/MeetingPipe/WorkflowMatcher.swift`) runs once, in `MeetingSessionController.beginRecording`, and its result fixes the capture mode (`CaptureMode.resolve(regulated:nda:redactMuted:)`), the sidecar's `workflow_nda_mode`, the backend and the sinks for that meeting. Re-read on 2026-10-24, each of these returns score 0 for an NDA rule and lets the default workflow win, with no trace:

- **Title not known yet.** `ruleScore` does `guard let title = source.meetingTitle, !title.isEmpty else { return 0 }`. A rule with both a bundle id and a title regex (score 3 when it matches) scores 0 when the title has not been scraped at record start, even though the bundle matched.
- **Invalid regex.** `titleMatches` is `guard let re = try? NSRegularExpression(...) else { return false }`. The Workflows editor (`WorkflowsView`, the `"title regex (optional)"` field) saves any string, and nothing validates it, so a typo makes the rule match nothing forever.
- **Manual recording.** `guard let source = source else { return 0 }`; expected and correct, listed so it is not mistaken for this bug.

And after the fact: `MeetingMetaSidecar` stamps `workflow_nda_mode` and `workflow_id` at record time. Switching a workflow to NDA later changes nothing for the meetings it already owns, so their sidecars still read `false`. Those meetings stay visible to `visibility.withheld_reason` (MCP, `mp ask`, `mp digest`) and a reprocess of one uses the cloud engine and the full sink list.

## Scope

1. **Say why the matcher chose.** `WorkflowMatcher.resolve` returns the workflow plus a reason: `.override`, `.matched(score)`, or `.fallback(undecided: [Workflow])`, where `undecided` lists NDA workflows that had a rule whose bundle id matched but whose title regex could not be evaluated (empty title or regex that does not compile). The function stays pure.
2. **Fail closed on undecided NDA.** In `beginRecording`, a fallback with a non-empty `undecided` list resolves the capture mode and the sidecar as NDA (the `.regulatedGate` capture, local backend, filesystem sink, which is what the NDA workflow would have done), stamps `workflow_nda_undecided: true` and the candidate's id in the sidecar, and logs an event. The Library row shows the meeting as NDA, and reassigning its workflow there (WF8's `reassignWorkflow`) is the existing way out. The alternative, holding every fallback meeting's summary for a confirm whenever any NDA workflow exists, was considered and is not the default: on a Mac with one NDA workflow it would gate most meetings; the owner can ask for it at pickup.
3. **Invalid regex is visible.** The Workflows editor validates the title regex on edit (compile it, show an inline error, refuse to save an uncompilable pattern), and `WorkflowInspector` flags an existing rule whose regex does not compile.
4. **Re-stamp on NDA turn-on.** When a workflow's `ndaMode` flips from false to true, offer once (a confirm sheet naming the count) to set `workflow_nda_mode = true` in the sidecar of every meeting whose `workflow_id` is that workflow. The sidecar writer is shared with the Swift/Python contract (CONVENTIONS.md sidecar schema), so the new key is added to both sides and `test_workflow_overlay.py`.

## Explicitly not

- Re-resolving the workflow mid-recording when the title arrives later. Capture mode is fixed at start by design (ADR 0016); scope item 2 is the start-time answer.
- What was already sent before NDA was turned on: a published summary cannot be recalled. The re-stamp covers what happens next.
- The routing editor's usability (bundle ids and regexes as raw text): UX88.
- MCP's global `regulated_mode` gap: AUTO6.

## Acceptance

- `WorkflowMatcherTests` gains: an NDA rule with bundle + regex and an empty title returns `.fallback` with that workflow in `undecided`; the same with an uncompilable regex; a non-NDA rule in the same situation is not listed; a matching title still returns `.matched(3)`; a manual recording (nil source) returns a plain `.fallback` with an empty list.
- A session test that an undecided fallback produces `.regulatedGate` capture and a sidecar with `workflow_nda_mode` true and `workflow_nda_undecided` true.
- A Workflows editor test (view-model level) that an uncompilable regex cannot be saved.
- A test that flipping a workflow to NDA and confirming rewrites exactly the sidecars carrying its `workflow_id`, atomically, and leaves others untouched.
- `test_workflow_overlay.py` covers the new sidecar key; the `CONVENTIONS.md` sidecar schema section gains the new key; `python3 scripts/truth_fences.py` clean.
- `swift test` and `pytest -q` green, new test counts in the commit body. GUIDE.md's workflow recipe mentions the undecided case in the same commit.

## Amended 2026-10-25 (observability audit band)

Three findings from the [observability audit](../../audits/2026-10-25-observability-audit.md) (SW-9, FB-6, PY-13) land here because they are the same failure one step earlier: before `WorkflowMatcher.resolve` can fail open on an NDA rule, the NDA workflow has to be loaded, and a workflow file that does not load, or loads with the wrong flags, fails open with no trace. Re-read in code on 2026-10-25. Latent on this Mac (the three workflow TOMLs parse and none is NDA); the trigger is a hand edit, which Preferences invites by revealing the folder, or a partial write.

### What the load path does today

- **An unparseable file vanishes.** `WorkflowStore.load` wraps `try Self.decode(url: url)` in `catch { Log.main.warning("WorkflowStore: skipping unreadable \(url.lastPathComponent): ...") }`: os.Logger only, so the reason is stored as `<private>`, and there is no file-log line, no event and no UI. The workflow is missing from the rail, its rules never reach the matcher, and its meetings take the default workflow's routing.
- **Fields decode toward cloud.** In `WorkflowStore.decode`, `flags.ndaMode = f["nda_mode"]?.bool ?? false`, so `nda_mode = "true"` (a string) decodes as not NDA; `doc["backend"]?.string.flatMap(WorkflowBackend.init(rawValue:))`, so `backend = "locl"` decodes as nil and inherits the global (cloud) backend; the rail shows the workflow normally in both cases.
- **A missing id is new every launch.** `let idString = doc["id"]?.string ?? UUID().uuidString` and `UUID(uuidString: idString) ?? UUID()`, so a file with no (or a bad) `id` gets a fresh UUID on each load. Meetings stamped with the previous `workflow_id` stop matching it, and `persistAll` writes `<new-uuid>.toml` beside the original file, a second copy per save.
- **Doctor misses it too.** `workflows._load_workflow_docs` does `except (OSError, tomllib.TOMLDecodeError, UnicodeDecodeError): continue` with no log at all. Its consumers are `nda_workflow_names`, which sets SEC12's cloud-sync severity in `mp doctor` (`zero_egress_promised = cfg.modes.regulated_mode or bool(nda_workflows)`), and `local_backend_workflow_names`, which gates doctor's local-stack check (UX21). So an NDA workflow whose file fails to parse turns doctor's cloud-sync FAIL into a WARN, and Python's `doc["flags"].get("nda_mode") is True` reads the string `"true"` as not NDA, the same as Swift.

### Added scope

5. **Keep a broken workflow visible and blocking.** `WorkflowStore.load` keeps an unparseable file as a broken entry (file name, error) instead of dropping it. The rail shows it as a broken row naming the file; while any broken entry exists, the matcher treats a fallback as undecided (item 2's `.fallback(undecided:)` path, so the meeting records under the NDA capture posture), because the broken file may be the NDA workflow. Logged to the daemon file log with `Log.event(category: "workflow", action: "load_skipped", ...)` carrying the file name and the error's domain and code.
6. **Strict decode for the three routing fields.** A present `nda_mode` that is not a TOML bool, a present `backend` that is not a known `WorkflowBackend`, or an `id` that is invalid, or missing when the file name is not itself a UUID (`persistAll` names every file `<id>.toml`, so a missing id is recoverable from the name), makes the file broken (item 5), not silently defaulted. A file with no `[flags]` table and no `backend` key still decodes as today; only a present, wrong value is refused.
7. **Doctor names it.** `_load_workflow_docs` returns the files it could not parse (or decode strictly, by the same rule as item 6) alongside the docs, and `mp doctor` prints one `[FAIL]` line per broken workflow file. While any exists, SEC12's check treats zero egress as promised.

### Added acceptance

- `WorkflowStoreTests`: an unparseable file, `nda_mode = "true"`, `backend = "locl"`, and a missing `id` in a file not named `<uuid>.toml` each load as a broken entry with the file name and do not appear as normal workflows; a well-formed file with no `[flags]` still decodes, and one missing `id` but named `<uuid>.toml` takes that UUID; loading twice does not create a second file for any of them. A `WorkflowMatcherTests` case that a broken entry turns a plain fallback into an undecided one.
- `test_workflows.py` and `test_doctor.py`: each broken shape is reported, `nda_workflow_names` is unchanged for good files, and doctor prints `[FAIL]` for a broken file and FAIL (not WARN) for a synced library while one exists.
- `python3 scripts/truth_fences.py events` green for `load_skipped`. The registry overlay (`meeting_apps.toml`) that is ignored with no log when it fails to parse belongs to OBS5's `registry_loaded` event, not here.
