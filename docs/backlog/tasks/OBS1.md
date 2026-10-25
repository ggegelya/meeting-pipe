# OBS1: 51 of the daemon's 60 warning and error sites log only to os.Logger, which stores their reason as `<private>` and never writes it to `~/Library/Logs/MeetingPipe`

Band origin: filed 2026-10-25 from the 2026-10-25 observability audit band ([audit](../../audits/2026-10-25-observability-audit.md) row O4; finders SW-4, FB-5, LG-2). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

This task is the band's shared primitive. OBS3, OBS4 and OBS5 emit their failure rows through the helper it adds, and UX91, SEC25, STOR9, STOR10 and SEC21 log their refusals through it rather than each inventing a pair of calls.

## Context

Verified in code on 2026-10-25 (base `01e904a`).

**Three log surfaces, one of which nobody can read.** `Log` in `daemon/Sources/MeetingPipe/Logger.swift` exposes `Log.main`, `Log.detector` and `Log.recorder` as plain `os.Logger(subsystem:category:)`, plus the two file writers `Log.event` (to `events.jsonl`) and `Log.writeLine` (to `<category>.log`). CONVENTIONS.md calls os.Logger the "use sparingly" surface for Console.app. os.Logger stores every dynamic string interpolation as private unless the call says `privacy: .public`, and exactly one site in `daemon/Sources` does (`TutorialSession`, `anchor.rawValue, privacy: .public`). The finders measured the result with `log show` on the 2026-10-24 `swift test` runs: `SavedSearchStore: write failed: <private>`, `PipelineFailureSidecar: write failed for <private>: <private>`, `failed to start recorder: <private>`. The unified log on this Mac also only held 7 days (earliest 2026-10-18). Diagnostics (`DiagnosticsLog`), `mp logs` and `mp doctor` read only the files.

**The count.** `grep -rnE 'Log\.(main|detector|recorder)\.(warning|error)\('` over `daemon/Sources` finds 60 sites. The skeptic pass found 9 with a `Log.event` or `Log.writeLine` in the same block (`WorkflowStore` duplicate names, `MeetingSessionController` mic permission missing and recorder start, the "Looks good" correction in `Coordinator+Delegates`, two in `SystemAudioCapture`, `Coordinator`'s mute-labels load and Accessibility denied, `SinkDispatcher`'s transcription failure). The finder's "none of ~60" was overstated; 51 have no file sibling. Of those, some are traced another way (the two per-buffer write errors feed `WriteFailureTracker`, `GlossaryStore` sets `saveError`, the config parse error is a Preferences row, trash failures return `.failure` to callers), and some are not failures at all (hotkey parse and collision notes in `Coordinator`, "cancelled by user" in `PipelineLauncher`, "refusing to delete the default workflow" in `WorkflowStore`).

**What is left with no trace anywhere a person can read**, each a failed write or load of user state:

- `SecretsStore`: `"SecretsStore persist failed: \(String(describing: error))"`, a Keychain write for an API key.
- `ConfigStore.scheduleSave`: `"ConfigStore persist failed: ..."` (ConfigStore has no `saveError`).
- `MeetingSessionController`: `"Failed to write meta sidecar: ..."` (its `writeLine` is on the success branch only).
- `PipelineFailureSidecar.write` and `.clear`: serialize, write and clear failures for `<stem>.error.json`.
- `WorkflowStore`: `"WorkflowStore: skipping unreadable ..."`.
- `SavedSearchStore` and `WorkflowCorrectionStore`: unreadable on load, failed on write.
- `LaunchAgentScheduler`: `mp not found`, plist write, and `launchctl` spawn failures.
- `WorkflowMigrator`: failed to seed the General workflow (its event is on the success path).
- `PipelineLauncher`: the Apple run-sidecar write, and the watchdog's `"mp ... exceeded ... min - terminating"`.
- `RosterRename`, `MeetingLibraryService` export copy, `LocalModelPreloader` and `ModelDownloadSupervisor` spawn failures, `HotkeyManager`'s `RegisterEventHotKey failed`, `Notifier`'s auth error, `SearchIndexer`'s index open failure, `MicLevelMonitor`, `LaunchAtLoginService`'s launchctl ceiling and spawn failure, `SummaryTab`'s correction write.

The cost is concrete. On 2026-10-16 the 09:46:34Z meeting failed with `$ANTHROPIC_API_KEY is not set`. Whether the key was never entered or a Preferences save failed at `SecretsStore` cannot be told from any file, and that site is exactly one of the 51.

## Scope

1. **One helper, three legs.** Add `Log.failure(category:action:error:attributes:file:)` and a `reason: String` overload for failures with no `Error` (`mp not found`). It writes:
   - a `Log.event` row with the caller's category and action, the caller's attributes, plus `error` (the localized description, capped at 300 characters as PIPE19's `stage_failed` caps `message`), `error_domain` and `error_code` (from the bridged `NSError`, which for a Swift error enum is its type name and case index);
   - a `Log.writeLine` sentence to `file` (default `"daemon"`, `"recorder"` for capture sites) naming the action, the description, and the domain and code;
   - one os.Logger `.error` line whose action, domain and code are `privacy: .public` and whose description stays default-private. The file logs are 0600 (SEC11); the unified log is readable by any admin, so content stays out of it.
2. **Migrate the failure sites listed above** to `Log.failure`, each with a snake_case action named for what failed (`secret_save_failed`, `config_save_failed`, `meta_sidecar_write_failed`, `failure_sidecar_write_failed`, `workflow_unreadable`, `schedule_install_failed`, `pipeline_watchdog_killed`, and so on) and the stem or file name as an attribute where the site has one. Categories reuse the CONVENTIONS table (`daemon`, `workflow`, `library`, `recorder`, `coordinator`); no new category.
3. **Leave behaviour alone.** Only the logging changes. Whether a failure should also reach the UI or refuse a write is owned elsewhere (see below).
4. **Fence it.** A source-scan XCTest in the `ConfigStoreFenceTests` shape (`daemonSourceFiles()`) fails on any `Log.main|detector|recorder` `.warning(` or `.error(` call outside a named allowlist. The allowlist holds the non-failure notes (hotkey parse and collision, cancelled by user, the default-workflow refusal, the tutorial anchor), the two per-buffer capture sites, and `Log.failure`'s own body, each with a one-line reason.
5. **Keep the truth fence seeing categories.** `scripts/truth_fences.py`'s `SWIFT_EMIT` and action regexes match `Log.event(` and `.emit(` only; extend both to `Log.failure(` so a category or a camelCase action passed through the helper is still fenced (CI5).
6. **Docs in the same commit.** CONVENTIONS.md "Logging: `Log.event` vs `Log.writeLine`" gains a `Log.failure` row and the rule "a failure is never os.Logger alone".

## Explicitly not / out of scope

- **The per-buffer write errors** in `MeetingRecorder` (`"mic write: ..."`) and `SystemAudioChannel` (`"system write: ..."`). They fire once per failed buffer, so a helper that writes two files per call would flood under a full disk. Counting them is REC22's.
- **UI for a failed save.** UX91 owns `saveError` on ConfigStore and SecretsStore and the Preferences and menu rows; it emits its event through this helper.
- **Behaviour at the failing sites.** SEC25 makes the meta-sidecar write throw and hold the job; STOR9 refuses to write over an unreadable store; STOR10 checks the schedule bootstrap; SEC21 decides what an unparseable workflow does. This task only makes each of them visible.
- **Logger threading and torn rows.** [PERF13](./PERF13.md) item 3 owns the serial queue; `Log.failure` calls `Log.event` and `Log.writeLine` and inherits whatever that lands.
- **Marking every os.Logger interpolation public.** It would put paths and titles into a log any admin reads and that the owner does not control.
- **Info and debug os.Logger lines.** Not failures; OBS6 decides what verbose output exists.

## Acceptance

- `LoggerTests` gains: `Log.failure` with an `NSError` writes one `events.jsonl` row carrying `error`, `error_domain`, `error_code` and the caller's attributes, and one line in the named `.log` file; a 1,000-character description is capped; the `reason:` overload writes the same shape with no domain; a Swift enum error records its type name as the domain.
- The new fence test passes on the migrated tree, and fails on a scratch source string with a bare `Log.main.error(` outside the allowlist.
- One test per migrated store family drives its failure branch with a fake (an unwritable directory, a failing Keychain shim) and asserts the row exists: SecretsStore, ConfigStore, PipelineFailureSidecar, SavedSearchStore, WorkflowStore. N new tests in the commit body.
- `python3 scripts/truth_fences.py events` green, and red on a scratch `Log.failure(category: "nope", ...)`.
- `cd daemon && swift build && swift test` green; `bash scripts/ci-local.sh` green.
