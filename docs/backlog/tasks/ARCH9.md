# ARCH9: config.toml has five independent Swift readers, a malformed file is silently replaced by defaults on the next Preferences save, and the cloud-token policy fails open on a parse error

Band origin: filed 2026-10-24 from the 2026-10-24 audit band ([architecture review](../../audits/2026-10-24-architecture-review.md) A3 and B6, [go-live assessment](../../audits/2026-10-21-go-live-assessment.md) PP-7 and PD-12). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Re-verified against `main` at `45b8c6a` on 2026-10-24. Neither CI8 nor DIST4 touched any of this: DIST4's `PipelineLauncher.swift` change is confined to `resolveDirectMP` and the venv path in `findMP`.

**Five Swift readers of one file**, each with its own parse and its own failure rule:

| Reader | Path source | On a parse error |
|---|---|---|
| `Config.load` in [`Config.swift`](../../../daemon/Sources/MeetingPipe/Config.swift) (used by `App`, `RosterRename`, `NotionDatabaseList`, `DoctorCommand`) | `Config.defaultPath` | throws; `App` logs "No config at ... using defaults" and runs on `Config.defaultFallback()` |
| `ConfigStore.init` in [`ConfigStore.swift`](../../../daemon/Sources/MeetingPipe/ConfigStore.swift) | injected, default `Config.defaultPath` | `(try? TOMLTable(string: raw)) ?? TOMLTable()`: an empty document, no signal |
| `PipelineLauncher.appleContext(for:)` | hard-coded `".config/meeting-pipe/config.toml"` | `try?`, team context and summary language silently default |
| `PipelineLauncher.cloudSecretPolicy(for:backendOverride:configURL:)` | `Config.defaultPath` | `regulated = false`, `globalBackend = "anthropic"` |
| `WorkflowMigrator.readLegacyTeamContext(at:)` | caller's URL | returns `""` |

**Silent data loss.** `ConfigStore` keeps the empty document as `rawDocument`, assigns every `@Published` field its `ConfigDefaults` value, and arms `scheduleSave`. The first Preferences edit then runs `writeBack()` (which writes only the keys it models) and `persistToDisk()` replaces the user's file atomically. Everything `writeBack` does not model (for example `summarization.team_context`, `obsidian.template_path`, workflow-era keys) is gone, and everything it does model is reset to its default, including `modes.regulated_mode`, which becomes `false`.

**Fail-open privacy.** On a malformed file the running daemon is not regulated even when the user's file says it is. The live capture decision reads the store: `MeetingSessionController` calls `CaptureMode.resolve(regulated: coordinator.configStore?.regulatedMode ?? false, ...)`, and `writeMetaSidecar` stamps the same value into `<stem>.meta.json`; on an empty document that field is `ConfigDefaults.regulatedMode`, so a regulated user gets a lossless capture and a sidecar that says the meeting was not regulated. `Config.defaultFallback()` carries the same default. `cloudSecretPolicy` keeps `ANTHROPIC_API_KEY` and `NOTION_TOKEN` in the child env because it reads `regulated = false`, and `NotionDatabaseList`'s default `isRegulated` closure is `(try? Config.load())?.modes.regulatedMode ?? false`, so the Notion database fetch is allowed. The Python side happens to fail closed: `mp.config.Config.load` calls `tomllib.load` with no handler, so every run dies on `TOMLDecodeError` before any egress, and surfaces as a generic `unknown` failure.

**Schema described in five places (B6).** `Config.swift`, `ConfigDefaults.swift`, `ConfigStore.swift`, `config.example.toml`, and `pipeline/src/mp/config.py`. `config.py` models four daemon-only keys that no Python code reads: `recording.auto_consent_apps` and all three `Detection` fields (`debounce_end_sec`, `manual_hotkey`, `prompt_timeout_sec`); a grep of `pipeline/src` outside `config.py` finds no reader. `recording.output_dir` stays, since `digest`, `ask`, `actions` and `backup` read it.

## Scope

1. **One Swift reader.** `ConfigStore` becomes the only Swift type that opens `config.toml`. Its load returns a result that records whether parsing failed (for example a `parseError: ConfigParseError?` carrying TOMLKit's message and, when its error exposes them, line and column) and keeps the raw text untouched.
2. **Refuse to save on a parse error.** While `parseError` is set, `scheduleSave` and `saveNow` do not write; `saveNow` throws. Preferences shows one persistent row ("config.toml has a syntax error at line N. Fix it in a text editor, then reopen Preferences.") instead of controls that pretend to edit. A reload after the file is fixed clears it.
3. **Fail closed.** Derive `Config` and the secret policy from the `ConfigStore` result. On a parse error the policy strips both tokens and the runtime treats regulated mode as on (the store's `regulatedMode` reads true, so `CaptureMode.resolve` takes the regulated gate and the sidecar says so) until the file parses. Preferences must not offer a regulated toggle that would write in this state, which item 2 already covers. `NotionDatabaseList`'s default `isRegulated` reads the same source and returns true on a parse error.
4. **Delete the hard-coded path** in `appleContext`, and route `cloudSecretPolicy`, `appleContext` and `WorkflowMigrator.readLegacyTeamContext` through the store (or a pure snapshot type it vends, so the static call sites stay testable).
5. **Retire `Config.swift`** as a separate parser: either `Config` becomes a value the store produces, or its fields move onto the snapshot. `scripts/truth_fences.py`'s `swift_read_keys` hard-codes `Config.swift` and `ConfigStore.swift` as its extraction sources, so update the fence in the same commit or it fails with "found no aliases".
6. **Drop the four daemon-only fields** from `config.py` (`extra="ignore"` already tolerates them in users' files), and make sure the CI5 config fence still sees each key read by its one reader.

## Explicitly not

- A config schema shared across trees (code generation, a JSON schema). Two readers, one per tree, each failing closed, is the target; the CI5 fence already catches drift between them.
- Rewriting `ConfigStore`'s TOMLKit round-trip or its `ensureTable` copy rule.
- Python's crash on a malformed file. It already fails closed; giving it a clear "config.toml syntax error" failure cause is an adjacency for the failure-metadata vocabulary (PIPE28 touches the same `FailureMetadata.Cause` enum and should land the two together if both are in flight), not this task.
- The backend id as a string in three Swift forms (ARCH14) and tokens mirrored through `setenv` (SEC23). Both touch `cloudSecretPolicy`'s neighbourhood; coordinate, do not merge.
- `workflows.toml`, `glossary.toml` and the meeting-app registry TOML. Separate files with their own readers.

## Acceptance

- `ConfigStoreTests`: a malformed file loads with `parseError` set and the raw text preserved; `saveNow` throws and the file's bytes are unchanged on disk after a simulated Preferences edit and the 500 ms debounce; a well-formed file round-trips exactly as today.
- `PipelineLauncherTests` (or the policy's new home): a malformed file strips both `ANTHROPIC_API_KEY` and `NOTION_TOKEN`; a well-formed regulated file still strips both; a well-formed non-regulated cloud file keeps both. The first case fails without the fix.
- A test that a store loaded from a malformed file reports `regulatedMode == true`, and that `CaptureMode.resolve` fed from it picks the regulated gate.
- A fence test (source text is acceptable here, following the CI5 pattern) that no file under `daemon/Sources` other than the store opens `config.toml` or calls `TOMLTable(string:)` on it.
- `cd daemon && swift build` and `swift test` green, new test count in the commit body. `cd pipeline && uv run --extra dev pytest -q`, ruff and pyright green. `python3 scripts/truth_fences.py config` green after the extractor update. `bash scripts/ci-local.sh` green before landing.
- `README.md` and `docs/GUIDE.md` say what a syntax error in `config.toml` now does, in the same commit.
