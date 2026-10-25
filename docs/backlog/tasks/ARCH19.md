# ARCH19: Meeting-app bundle ids drive switch statements in four files and literals in nine, so adding a meeting app means editing six or more files

Band origin: filed 2026-10-25 from the 2026-10-25 code-quality audit band ([code-quality audit](../../audits/2026-10-25-code-quality-audit.md) SW6). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

## Context

Re-checked at filing on 2026-10-25: of the nine Swift files that carry the quoted `"us.zoom.xos"`, two are a doc comment (`LibraryWindow`) and a text-field placeholder (`PreferencesView+Recording`), so seven are code; the switch count (four files) holds, and the fence is weaker than the audit credited, because two drifts already sit behind it.

`MeetingAppRegistry` (DET4) owns the bundle *sets*: it loads `Resources/meeting_apps.toml` plus a user overlay and hands `MeetingSourceScanner` its native, browser and fragment lists. Everything an app *does* is still keyed by string literals, one copy per concern:

- Core: `NativeLifecycleConfig.teams/.zoom/.webex/.slack` and `NativeLifecycleConfig.all`; `NativeAppMuteConfig.teams/.zoom/.webex/.slack` (no `all`); `MeetingTitlePatterns`; `MuteLabels.toml` keyed by app name.
- Executable: `MeetingAXHandleBuilder.appNameByBundle`, plus two `switch bundleID` blocks in the same file (`callingControlsToolbarNeedles(bundleID:)` and `matchesLeave(bundleID:title:help:description:)`); `MeetingSourceScanner.isActiveMeetingWindow` (`switch (bundleID, kind)`); `MeetingTitleResolver.rawMeetingTitle` (same shape); `AppGlyphView.filename(for:)`; `DoctorCommand.knownMeetingBundleIDs`, a hand-copied list of the TOML's six native ids; and `Coordinator.init`, which constructs four `NativeLifecycleAdapter`s and four `NativeMuteAdapter`s by name.

A new native app therefore touches about ten source and resource files plus the fence test. `MeetingAppRegistryFenceTests` (nine tests) pins four of those seams against the bundled TOML: a `NativeLifecycleConfig` in `all`, an `appNameByBundle` entry, an `isActiveMeetingWindow` branch (via a representative title), and the browser set. The rest are unfenced, and two have already drifted:

1. **`MeetingTitleResolver.rawMeetingTitle` has no `com.cisco.spark` case.** DET4 added the unified Webex App to the TOML, the scanner, `appNameByBundle`, both `MeetingAXHandleBuilder` switches and both configs, but `rawMeetingTitle` still matches only `("com.cisco.webexmeetingsapp", _)`, so a spark window falls to `default` and returns nil (kind is `.native`). Read from code; `MeetingTitleResolverTests` has no Webex case, and DET15 counts one Webex trace in the corpus.
2. **`NativeLifecycleConfig.all`'s doc comment is false.** It says "The daemon builds one `NativeLifecycleAdapter` per entry (see `Coordinator`)", but `Coordinator.init` lists the four configs by hand. A fifth config added to `all` passes the fence and is never constructed.

Smaller: `AppGlyphView.filename(for:)` still carries `case "com.google.meet"`, which DET4 removed as dead (Meet is browser-only), and Webex's glyph fallback is by asset (none exists), not by omission. And the overlay's `[native]` table can list an app but not make it work: an overlay native id has no recognizer branch (`isActiveMeetingWindow` answers `default: return false`), no lifecycle adapter and no mute adapter, while the registry's doc comment says the overlay lets the owner "add a bundle without a rebuild". That holds for `[browser.bundles]` and `[mic_plausible]` only.

## Scope

**Step 1 is an owner decision, asked before any code.** Both options also do step 2.

- **Option A, a `MeetingApp` descriptor.** A Core `enum MeetingApp: CaseIterable { case teams, zoom, webex, slack }` with `init?(bundleID:)`, `bundleIDs`, and `muteCatalogueKey`; `NativeLifecycleConfig` and `NativeAppMuteConfig` become lookups on it; every executable `switch bundleID` becomes an exhaustive `switch MeetingApp(bundleID:)`, so a new case is a compile error at each switch that forgot it; `Coordinator` iterates `MeetingApp.allCases`; the TOML `[native]` list is validated against the enum at load and an overlay `[native]` id with no case is logged once and dropped. The predicates, needles and title extractors move unchanged. Cost: M, about ten files, every detection switch rewritten just after END17 landed in the same code; the main risk is a lost `kind` qualifier (`("com.microsoft.teams2", .native)` is native-only), which the existing scanner tests cover.
- **Option B, extend the fence.** Keep string keys. Add fence tests for the unfenced seams: every bundled native has a `rawMeetingTitle` branch (a representative title per bundle, which fails today on spark), a non-default `callingControlsToolbarNeedles` answer and a `matchesLeave` hit on a representative English label; `NativeAppMuteConfig` gains an `all` and the fence asserts it covers the TOML; `AppGlyphView` gets an explicit per-bundle table the fence checks (fallback listed by name, not by omission). `DoctorCommand.knownMeetingBundleIDs` reads `MeetingAppRegistry.bundled.nativeBundles` instead of its own copy. Cost: S, about four test additions and two small source changes; adding an app still means ten files, but each omission fails a test naming the file.

Recommended default if the owner does not choose: **B**. The native set changed once in a year (DET4's spark), nothing new is planned, and DET15 will reshape the leave labels and needles into a catalogue, which is the part A would otherwise move twice.

**Step 2, both options:** add the missing `com.cisco.spark` case to `MeetingTitleResolver.rawMeetingTitle`; make `Coordinator` build its native lifecycle and mute adapters from `NativeLifecycleConfig.all` and `NativeAppMuteConfig.all` (passing `halBus` only when `usesProcessAudio`), which makes the `all` doc comment true; delete the dead `com.google.meet` glyph case; correct `MeetingAppRegistry`'s overlay comment to say `[native]` overlay rows need code (option B) or are dropped (option A).

## Explicitly not / out of scope

- Localized leave labels, toolbar needles and accent-folded title matching: [DET15](./DET15.md) (P3). Neither option translates a string.
- Browser meeting detection beyond Meet: [DET6](./DET6.md).
- The config-root path that `MeetingAppRegistry.defaultOverlayURL` spells by hand: ARCH18, filed the same day.
- A Webex glyph asset: design work, not filed.
- END17's end tiers: no predicate's behaviour changes here.

## Acceptance

- The owner's A or B choice is recorded in this spec before code lands.
- `MeetingTitleResolverTests`: a spark window titled like a live Webex meeting yields the same title as `com.cisco.webexmeetingsapp` (fails on `main`).
- A fence or Coordinator test that the constructed native lifecycle and mute adapters' bundle ids equal the TOML `[native]` set (fails if `Coordinator` drops a config).
- Option B: the new fence tests, each red when its seam's entry for one bundle is removed (tried and reverted, stated in the commit body). Option A: every converted switch is exhaustive with no `default`, and the overlay test shows an unknown `[native]` id dropped with one log line.
- `cd daemon && swift build` and `swift test` green; `bash scripts/ci-local.sh daemon` green; new test count in the commit body.
