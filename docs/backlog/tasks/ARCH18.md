# ARCH18: The app's on-disk folders are spelled by hand at ten sites that bypass Endpoints.Paths, four of them the config folder

Band origin: filed 2026-10-25 from the 2026-10-25 code-quality audit band ([code-quality audit](../../audits/2026-10-25-code-quality-audit.md) SW5). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Re-read in code on 2026-10-25 (base `01e904a`). Re-checked at filing: the audit's "config root spelled by hand at 8 sites" mixes three roots; the config folder itself is bypassed at four sites, and counting the Application Support, Caches and Logs folders as well it is ten, so the title says that.

`Endpoints.Paths` is meant to be the one list of where the daemon reads and writes. It holds six config-folder constants, each spelling the folder again in full (`configRelative = ".config/meeting-pipe/config.toml"`, `secretsRelative`, `voiceprintRelative`, `rosterRelative`, `glossaryRelative`, `lastBackupRelative`), plus `logsRelative`, `recordingsRelative` and `correctionsRelative`. There is no constant for any folder, only for files in it. `Config.defaultPath`, `GlossaryStore`, `LastBackup`, `RosterProfile`, `VoiceprintProfile`, `Log.resolveLogsDir` and `CorrectionStore.directory()` go through it. These ten do not:

**Config folder (`~/.config/meeting-pipe/`), four sites:**

- `MeetingAppRegistry.defaultOverlayURL`: `.appendingPathComponent(".config/meeting-pipe/meeting_apps.toml")`
- `WorkflowStore.defaultDirectory`: `".config/meeting-pipe/workflows"`
- `WorkflowCorrectionStore.defaultURL`: `".config/meeting-pipe/workflow_corrections.json"`
- `SavedSearchStore.defaultURL`: `".config/meeting-pipe/saved_searches.json"`

**Application Support (`~/Library/Application Support/MeetingPipe/`), two sites,** beside `CorrectionStore`, which does it through `Endpoints.Paths.correctionsRelative`:

- `ConsentStore.init`: `"Library/Application Support/MeetingPipe"` then `auto_consent.json`
- `MuteRedactor.originalsDirectory`: `FileManager.default.urls(for: .applicationSupportDirectory, ...)` then `"MeetingPipe/originals"`, falling back to `temporaryDirectory`

**Caches (`~/Library/Caches/MeetingPipe/`), three sites, no `Paths` entry at all:**

- `NotionDatabaseList.defaultCacheURL`: `"Library/Caches/MeetingPipe/notion-databases.json"`
- `SearchIndexer.defaultIndexURL`: `.cachesDirectory` then `"MeetingPipe/search/index.sqlite"`
- `WaveformPeaks.cacheDirectory`: `.cachesDirectory` then `"MeetingPipe"` / `"waveforms"`

**Logs, one site:** `LaunchAgentScheduler.logDir` spells `"Library/Logs/MeetingPipe"` although `Endpoints.Paths.logsRelative` exists.

In all, `.config/meeting-pipe` occurs 26 times in `daemon/Sources`: 15 in doc comments, 6 in the `Paths` constants, 4 at the bypass sites above, and one user-visible copy line in `PreferencesView+Advanced` (twice on that line). ARCH9's `ConfigStoreFenceTests.test_the_config_path_is_spelled_once` already fences the `config.toml` path; nothing fences the folder, so a rename is a ten-file hunt in which each miss writes a file to the old place silently. This is a hygiene and drift cost, not a live bug: every site resolves to the right folder today.

## Scope

1. **Folder constants in `Endpoints.Paths`:** `configDirRelative = ".config/meeting-pipe"`, `appSupportRelative = "Library/Application Support/MeetingPipe"`, `cachesRelative = "Library/Caches/MeetingPipe"`, with the six existing config-file constants rewritten to derive from `configDirRelative` (their string values unchanged, so `Config.defaultPath` and ARCH9's fence are untouched), and `correctionsRelative` from `appSupportRelative`. Add three `URL` accessors resolved against `homeDirectoryForCurrentUser`, the way every existing `Paths` user already resolves: `Endpoints.Paths.configDir`, `appSupportDir`, `cachesDir`.
2. **Migrate the ten sites** to those accessors. The three `FileManager.urls(for:)` sites resolve to the same folder because the app is not sandboxed (no `app-sandbox` entitlement anywhere in the repo); their `temporaryDirectory` fallback never fires for `.userDomainMask` and goes. `LaunchAgentScheduler.logDir` uses `Endpoints.Paths.logsRelative` from home, deliberately **not** `Log.logsDir`: the plist outlives the process, and baking a `MEETINGPIPE_LOGS_DIR` override or the XCTest temp redirect into a persistent LaunchAgent would be a new bug.
3. **Fence it.** A `PathsFenceTests` (MeetingPipeTests, the CI5 source-text pattern `ConfigStoreFenceTests` uses) that fails on a non-comment line outside `Endpoints.swift` containing `.config/meeting-pipe`, `Application Support/MeetingPipe`, `Caches/MeetingPipe`, `Logs/MeetingPipe` or `appendingPathComponent("MeetingPipe`, with an allowlist of exactly one entry: `PreferencesView+Advanced.swift`, the user-visible copy, with its reason.

## Explicitly not / out of scope

- `config.toml`'s readers and their failure rule: ARCH9 (landed 2026-10-24, in [q6-final.md](../q6-final.md)). This task does not touch `ConfigStore` and leaves `configRelative`'s value as it is.
- Per-meeting sidecar paths in the recordings folder (`<stem>.summary.json` and kin): ARCH10's `MeetingFiles`.
- `recordingsRelative` and the user-chosen output folder, which `ConfigStore.outputDirPath` already owns.
- The Python side, where `storage.py` has a config-folder helper (`Path.home() / ".config" / "meeting-pipe"`) that `config.CONFIG_PATH`, `roster.ROSTER_PATH` and `voiceprint.VOICEPRINT_PATH` bypass by spelling `~/.config/meeting-pipe/...` themselves. Observed and unfiled; the natural home is the same audit's Python small-duplication sweep (proposed as HYG16), not this task.
- Doc comments that spell the folder for a human reader, and `docs/GUIDE.md` / `docs/SETUP.md` prose.

## Acceptance

- `PathsFenceTests`: the fence passes after the migration, and fails when one of the old literals (say `WorkflowStore.defaultDirectory`'s) is restored, tried and reverted, said in the commit body.
- An `EndpointsPathsTests` case pinning each derived constant to its literal string today (`configRelative == ".config/meeting-pipe/config.toml"`, and so on for all nine), so the derivation cannot change a path silently.
- Existing `ConfigStoreFenceTests`, `WorkflowStoreTests`, `SavedSearchStoreTests`, `ConsentStoreTests` and `WaveformPeaksTests` green unchanged.
- `cd daemon && swift build` and `swift test` green, about 3 new tests with the count in the commit body; `bash scripts/ci-local.sh daemon` green.
