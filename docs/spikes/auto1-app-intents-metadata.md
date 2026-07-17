# AUTO1 spike: native App Intents without an Xcode project (the metadata-processor question)

Spike, 2026-07-18. Probe: [`daemon/scripts/auto1-app-intents-probe.sh`](../../daemon/scripts/auto1-app-intents-probe.sh) (owner-run on a real Mac with full Xcode; self-contained, touches nothing in the repo or the installed app). Unlike the DET2 / MIC7 / MIC8 spikes, the headline mechanism question IS answerable in-harness and this spike answers it: the metadata bundle can be built off a SwiftPM-style compile. What stays owner-owed is only the last mile, that Shortcuts.app actually surfaces the action, which needs an interactive Mac with the app installed.

## Question

AUTO1's `meetingpipe://` URL scheme shipped and its acceptance is met (a Shortcut driving the built-in "Open URL" action toggles a recording end-to-end; Raycast and Stream Deck ride the same way). The one substantive remainder is **native App Intents**: a first-class, no-URL-typing Shortcuts action. The spec deferred it on a toolchain fact, that a plain `swift build` never runs `appintentsmetadataprocessor`, the build phase Shortcuts needs to discover App Intents, so shipping intents on the SwiftPM bundle alone would be undiscoverable dead code. Lighting them up meant "either moving the build to Xcode or invoking the metadata processor in install.sh, a separate spike that DIST1's build-system question may force anyway".

AUTO1 asks the narrow, empirical version of that: **can `appintentsmetadataprocessor` be driven off the existing `swift build` product, entirely from install.sh, and produce a valid `Metadata.appintents` bundle?** If yes, the App Intents leg is a bounded build, not a build-system migration; if no, the durable answer is an Xcode project (or an Apple-provided SwiftPM plugin) and the decision belongs with DIST1.

## What is already in place (so a GO is small)

The whole automation surface AUTO1 needs already exists and is unit-tested; App Intents add a discovery skin over it, not new behaviour:

- **The command vocabulary.** `AutomationCommand` (the pure, tested parser) already models the six verbs: `toggle`, `record` (+ a `byo` variant), `stop`, `library` (with a `scope`), `ask` (with a question), `digest`.
- **The gated router.** `Coordinator+Automation.handleAutomation` routes each verb through exactly the session entry points the global hotkey uses, so a denied mic still deeplinks to Permissions and `record` never stacks a second recording. An App Intent's `perform()` does not re-implement any of this: it posts the same `meetingpipe://<verb>` URL (or calls the same router), so there stays **one gate path**, not a parallel one.
- **The receiver + registration.** `AppDelegate.application(_:open:)` and the `CFBundleURLTypes` entry in `scripts/install.sh` already deliver deeplinks to the running daemon.

So a GO build's surface is: N small `AppIntent` structs mirroring the verbs, one `AppShortcutsProvider` exposing the zero-argument ones (toggle / record / record-byo / stop / digest) as no-typing actions and the parameterized ones (library-scope, ask-question) as configurable actions, and one install.sh metadata step. No fusion, gate, or routing change.

## The mechanism, measured (not guessed)

The probe reproduces, by hand, what an Xcode "App Intents Metadata Extractor" phase does, and it works on this toolchain (Xcode 17F42, macOS 26 SDK 25F70; `extract.actionsdata` format 3.0). Two steps, both runnable in install.sh right after `swift build`:

1. **A supplementary `swift-frontend` const-values pass** over just the App Intents source files. `swift build` does not emit const-values, but a separate frontend invocation does: `swift-frontend -c -primary-file <abs source> -parse-as-library -emit-const-values-path <out> -const-gather-protocols-file protocols.json`. The compiler writes a `.swiftconstvalues` JSON describing every type that conforms to the gathered protocols (the `AppIntent`, its `title`, the `AppShortcut` phrase, etc.).
2. **`appintentsmetadataprocessor`** consuming that: `--source-file-list`, `--swift-const-vals-list`, plus `--toolchain-dir --module-name --sdk-root --xcode-version --platform-family --deployment-target --target-triple --output`. It writes `Metadata.appintents/{extract.actionsdata, version.json}`.

Verified end-to-end: the emitted `extract.actionsdata` names `MeetingPipe.ToggleRecordingIntent`, its title "Toggle Meeting Recording", the App Shortcut phrase "Toggle recording in ${applicationName}", and the short title. The bundle is real and well-formed, not empty scaffolding.

Four traps the probe encodes so a build does not rediscover them (each cost real time here, and each would look like "App Intents are impossible off SwiftPM" if hit blind):

- **Protocol names must be bare, not module-qualified.** `["AppIntent","AppShortcutsProvider"]` gathers the conformances; `["AppIntents.AppIntent", ...]` silently gathers nothing (an empty `[]` const-values file).
- **`-const-gather-protocols-file` must go straight to the frontend.** Passed through the driver as `-Xfrontend`, it reaches the wrong stage and yields `[]`.
- **Source paths must be absolute.** The processor matches each const-value's `file` field against `--source-file-list`; a relative primary-file makes it fail with "Unable to find matching source file". Xcode always passes absolute paths; install.sh must too.
- **`-parse-as-library`** is needed so a top-level-code-free intents file compiles as a frontend unit.

## The fragility axis (why this stays behind the probe, and ties to DIST1)

The mechanism works, but it is built on a **private, undocumented surface**: the `-emit-const-values-path` / `-const-gather-protocols-file` frontend flags, the processor's argument list, the `protocols.json` contents, and the `actionsdata` format (stamped `3.0` / `17F42`) are Xcode-internal and can shift on a toolchain bump. A silent break here is the worst kind: the app builds, installs, and runs, but the Shortcuts action quietly stops appearing. That is exactly why this is a probe, not a one-line install.sh addition merged on trust: the probe is the **regression guard**, re-run after any Xcode update to confirm the bundle still builds before shipping.

The non-fragile home for this is a build system that runs the phase natively: an Xcode project (the phase is a checkbox) or an Apple-provided SwiftPM plugin (none exists today). That is precisely the choice **DIST1** owns (bundle-a-runtime / build-system question). If DIST1 stays on SwiftPM, the install.sh hand-roll is the pragmatic path and the probe keeps it honest; if DIST1 moves to an Xcode project, the metadata phase comes for free and the hand-roll retires. Either way, the App Intents metadata step should be decided **with** DIST1, not bolted on ahead of it.

One more non-blocking design note for the build: on macOS the metadata bundle lives inside the signed app (the processor's `--output` points at the app's `Contents`/`Contents/Resources`), so install.sh writes it before the existing re-sign pass, and the discovery eyeball is what confirms the placement + signature are right for Launch Services to index.

## Verdict: mechanism GO (proven here), build timing the owner's call, discovery eyeball owner-owed

- **Mechanism: GO, proven in-harness.** `appintentsmetadataprocessor` can be driven off the SwiftPM build via the const-values pass, and emits a valid `Metadata.appintents` naming the intent + its Shortcuts phrase on the current toolchain. The spec's "undiscoverable dead code" blocker is lifted for the metadata-build half: install.sh CAN produce the metadata Shortcuts reads.
- **Build timing: the owner's call, and now a bounded build.** It is no longer blind: N intents + one provider + one install.sh step, all routed through the shipped, tested `handleAutomation` gate. Two residual risks, both named and mitigated: the final Shortcuts-discovery eyeball (owner-owed, one-time), and toolchain-bump fragility of the private flag surface (probe-guarded, re-run on each Xcode bump).
- **Durable path: converge with DIST1.** Fold the metadata step into whatever build system DIST1 blesses. Do not hand-roll it into install.sh ahead of that decision unless the owner wants the native Shortcuts action sooner than DIST1 lands.

Net: **do not add App Intents to the shipping build yet.** The URL scheme already meets AUTO1's acceptance; native App Intents are a discoverability upgrade whose metadata mechanism is now proven and whose build is now bounded. Keep this doc + the probe; promote on the owner's go.

## Follow-on

- Owner: run `bash daemon/scripts/auto1-app-intents-probe.sh` (full Xcode required). A `MECHANISM GO` confirms the path on your toolchain. Then the one thing the probe cannot do: build the daemon with an App Intents leg lit, open Shortcuts.app, and confirm a "Toggle Meeting Recording" action appears and toggles a recording end-to-end.
- On GO + owner go-ahead: add the six `AppIntent` structs + `AppShortcutsProvider` (each `perform()` posting the matching `meetingpipe://` URL so the gate path stays single), and the install.sh const-values + processor step (placed before the re-sign pass), decided together with DIST1's build-system choice.
- On a future `MECHANISM NO-GO` (a toolchain bump moved the private surface): stop trusting the install.sh hand-roll, and make the App Intents leg the forcing function for DIST1 to pick an Xcode project. The `meetingpipe://` URL scheme keeps AUTO1's acceptance intact in the meantime.
