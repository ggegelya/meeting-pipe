---
id: SEC21
title: NDA workflow classification fails open: a meeting whose title is not known yet, or whose rule regex does not compile, silently falls through to the default (non-NDA) workflow, and turning NDA on later does not cover past meetings
category: Security
status: new
priority: P2
comment: Filed 2026-10-24 (audit band, arch S7): WorkflowMatcher scores an NDA rule 0 when the title is not known at record start or its regex fails to compile, so the default workflow wins with no trace, and workflow_nda_mode is stamped only at record time. Matcher returns a reason, an undecided NDA fallback records as NDA, the editor rejects bad regexes, turning NDA on offers a re-stamp of that workflow's past meetings. [Spec](./SEC21.md) Amended 2026-10-25 (observability band): SW-9, FB-6, PY-13 add the load step. An unparseable workflow file vanishes from the app (os.Logger only) and from doctor (no log), `nda_mode = "true"` or a backend typo decodes toward cloud, a missing id is a new UUID each launch. Keep broken files as blocking rail entries, strict decode, doctor FAIL. Amended 2026-11-13 by the audit band: title=(none) on 155 of 155 recordings since 2026-09-01 makes the unknown-title case the normal one, the browser branch reads any window's title, and the inspector shows a blank-rule workflow as Any meeting while it scores 0; matched-window title, a no-title event, an owner call on title-only rules, Trigger row from the matcher (F040, G013).
---

# SEC21: NDA workflow classification fails open: a meeting whose title is not known yet, or whose rule regex does not compile, silently falls through to the default (non-NDA) workflow, and turning NDA on later does not cover past meetings

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) S7). Status and priority live in this file's header; [INDEX.md](../INDEX.md) lists every task.

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

## Amendment 2026-11-13 (audit band)

From the [2026-11-12 independent audit](../../audits/2026-11-12-independent-audit.md) (F040 confirmed, G013 partially confirmed) and the [field evidence](../../audits/2026-11-13-field-evidence.md) (daemon health and audit cross-check, finding 5). Re-read in code at HEAD on 2026-11-14. The field data turns this task's "title not known yet" case from an edge into the normal case.

### What the field shows (F040)

The daemon.log line `MeetingSessionController` writes at stop, `"meta sidecar → ... title=\(source?.meetingTitle ?? "(none)") workflow=..."`, reads `title=(none)` on 391 of 402 recordings in the pack. By month a title was present on 0 of 40 (May), 1 of 68 (June), 8 of 59 (July), 2 of 80 (August), 0 of 85 (September), 0 of 48 (October) and 0 of 22 (November): 155 of 155 without a title since 2026-09-01, still so in the 2026-11-12 build. None of the 113 `<stem>.meta.json` files in the pack carries a `meeting_title` key. So every title-keyed rule in `WorkflowMatcher.ruleScore` has scored 0 (`guard let title = source.meetingTitle, !title.isEmpty else { return 0 }`) on every recording since September. Latent for routing in the pack (from the work laptop) only because all 113 meetings used one non-NDA workflow.

Two causes in `MeetingTitleResolver.rawMeetingTitle`:

- **The Teams extractor predates the current window titles.** `extractTeamsNativeTitle` accepts only `^\s*Meeting (?:in|with)\s+(.+?)\s*\|\s*Microsoft Teams\s*$`, while `MeetingSourceScanner`'s own comment says Teams "dropped the "Meeting in/with <X>" prefix - title is now just the topic". That fix belongs to [CAL3](./CAL3.md) (deferred, P3), whose next leg is gated on the [VALOWN1](./VALOWN1.md) probe (P4); this field count is input to that verdict and is not re-scoped here.
- **The browser branch reads every window of the browser.** It is `titles.lazy.compactMap(extractBrowserMeetingTitle).first` over `MeetingSourceScanner.collectAXWindowTitles(pid:)`, so the first brand-matching title in any window of that browser wins, not the title of the window or tab that matched the meeting. Not filed anywhere before this amendment. The seam is wider than the resolver: `MeetingSessionController.resolveAppSource(from:)` calls `MeetingTitleResolver.resolve(bundleID:kind:pid:)` with only the pid, and `MeetingLifecycleContext` carries `bundleID`, `kind`, `pid` and an optional `title` ("Best-effort title for the event log") but no window.

**What this does to item 2.** Item 1 lists an NDA workflow as undecided when "a rule whose bundle id matched" has a title regex that "could not be evaluated (empty title ...)". With no titles at all, item 2 would record every call from an app named by an NDA workflow's bundle-plus-regex rule as NDA, which is the "would gate most meetings" outcome item 2 rejected for the hold-for-confirm alternative. And a title-only NDA rule (blank bundle id) is never undecided under item 1's wording, so it is a dead rule that fails open on every meeting. Neither reading is safe while titles are absent; the choice goes to the owner below.

### The inspector says a blank rule matches everything (G013)

`WorkflowInspectorPresentation.triggerRow` renders a workflow whose rules all have both fields blank as `value = "Any meeting"`, under the comment "A rule with both fields blank is a real thing to author, and it matches everything" (UX33's copy, shipped 2026-07-29). `WorkflowMatcher.ruleScore` says the opposite: `if !bundleSet && !regexSet { // Empty rule (no fields filled) can't match anything; rely on the default. return 0 }`. For the default workflow the difference is invisible, since it wins the fallback anyway. For any other workflow, an NDA one included, the pane reads "Any meeting" while the matcher never picks it, and an app on the auto-consent list (`coordinator.liveAutoConsentApps` or `consent.isAutoConsented`) skips the prompt panel where the owner could pick it by hand, so the call falls to the default workflow's backend and sinks. [UX88](./UX88.md) covers regex validation and the raw-text editor, not blank rules.

### Added scope

8. **Take the title from the window that matched (F040, browser half).** Thread the title of the window or tab the browser match decided on into the start path (the producer of the `.starting` context, or a window identifier the resolver can use), so `resolveAppSource` reads that window's title rather than walking every window of the pid. The pickup session traces where the browser match picks its window and names the seam in the commit; this is a change to the context's producer and the resolver together. The Teams extractor stays with CAL3.
9. **Make a missing title visible (F040).** At record start, when the source is non-nil and `meetingTitle` is nil, emit `coordinator`/`meeting_title_unresolved` with `bundle_id`, `kind` and the count of window titles read, and never a title string ([SEC38](./SEC38.md) is removing titles from the logs). The drift that went unseen from September to November becomes one countable event.
10. **Pin item 1's title-only case, by the owner's decision (F040).** Before item 2 ships, the owner decides how a title-only NDA rule with an unknown title counts (undecided, or not), knowing that with today's titles "undecided" gates every recording with a source; item 1's wording and its `WorkflowMatcherTests` follow that answer. If the owner prefers, item 2 waits for CAL3's extractor fix.
11. **One answer for "does this rule match" (G013).** Give `WorkflowMatcher` a pure helper that says whether a workflow's rules can ever score above 0 (an all-blank rule set cannot), and derive the inspector's Trigger row from it, so a non-default workflow with only blank rules reads like one with no rules ("Nothing matches this automatically", with the pick-by-hand detail) and the default keeps "Any meeting no other workflow claims". The Workflows editor drops a rule whose two fields are both blank at save.

### Added acceptance

- `WorkflowInspectorPresentation` tests: a non-default workflow with only blank rules reads the no-match copy; the default workflow is unchanged; a table of rule sets checks that the Trigger row's "matches" claim agrees with `WorkflowMatcher.resolve` over a set of synthetic sources (native with and without a title, browser, nil).
- A Workflows editor test (view-model level, beside item 3's regex test) that a rule with both fields blank is dropped at save and a rule with either field filled is kept.
- `MeetingTitleResolver` (or the new seam) test with synthetic titles only: a browser with two windows whose first carries an unrelated brand-matching title and whose second is the matched meeting window resolves the second.
- A session-level test that a record start with a source and no title emits `meeting_title_unresolved` with no title attribute; `python3 scripts/truth_fences.py events` green, the action documented in CONVENTIONS.md's `coordinator` paragraph.
- GUIDE.md's workflow recipe says a blank rule matches nothing, in the same commit as item 11.

### Owner walkthrough (amendment)

1. [owner] Decide item 10: does a title-only NDA rule with an unknown title count as undecided, and does item 2 ship before CAL3's Teams extractor fix?
2. [owner] After landing, rebuild and record one browser meeting with two browser windows open, then confirm that the meeting's sidecar carries the meeting tab's title, and that `meeting_title_unresolved` appears for a native Teams call while CAL3 is open.
