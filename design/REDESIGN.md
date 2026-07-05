# Redesign 2026-07: Liquid Quiet + Instrument

Owner-approved 2026-07-05 (proposal: three directions, hybrid 1+2 chosen). This file is the **single spec owner** for backlog tasks **DSN20-DSN29** and the design half of **UX15**; backlog rows are one-liners pointing here. It contains the exact prompts to hand to Claude Design, in order, plus the port map back into Swift.

## The decision

The substrate is **Liquid Quiet**: the existing personality (one teal accent that means capture, coral reserved for recording, quiet truthful copy) wearing the macOS 26 material language. Cool porcelain neutrals replace the warm-paper canvas, buttons become capsules, radii grow one notch and stay concentric, floating chrome leans into real glass, and every surface gets exactly one type anchor. On top of that, the capture surfaces (prompt panel, recording HUD, record controls, menu-bar states) adopt the **Instrument** control language: a circular record key with visible travel, LED-segment meters, SF Mono numerals, mechanical motion. The Library additionally gets a UX pass driven by the 2026-07-05 audit.

### Amended DESIGN.md rules (rewritten properly in DSN29)

- **Retired:** the warm-paper canvas. Paper/ink hue bias goes cool-neutral; the "calm document" motif is carried by layout and type, not by cream.
- **Amended:** buttons move from the 6px bezel to capsules (macOS 26). Inputs stay rectangular at 8px.
- **Amended:** the Thirteen-Pixel rule becomes **one anchor per surface**: chrome stays 13px, but each surface gets exactly one larger anchor (prompt question 14, HUD timer 21 then 24 under Instrument, pane titles 15-17). Nothing else inflates.
- **Amended:** press feedback may scale controls to 0.97 (was translate-only). Motion stays springless and short.
- **Amended (capture surfaces only):** numerals set in SF Mono tabular; the record action is a circular key, a deliberate exception to the one-button-language rule; meters are discrete segments.
- **Unchanged:** One Signal (about 10% of any surface), Coral-Is-Recording, Hairlines-Not-Shadows, Float-Earns-Blur, no gradients, no emoji, no exclamation marks, sentence case, ellipsis semantics, the a11y floor, fixed window sizes.

## How to run a design pass (applies to every prompt below)

**Venue.** Either a claude.ai Claude Design session on the synced design-system project (push current state first with `/design-sync`), or a local Claude Code session in this repo. The prompts are self-contained because the root docs (PRODUCT.md, DESIGN.md) are not part of the `design/` sync unit. Results always land in `design/` and are committed here; the repo is the source of truth, the Claude Design project is the gallery.

**Ground rules for every pass:**

1. Design passes touch only `design/` (tokens + `ui_kits/macos_app/`). No Swift.
2. Change token **values** in `colors_and_type.css`; never rename an `--mp-*` variable (the Swift mirror `daemon/Sources/MeetingPipe/Design/Tokens.swift`, `DesignTokensTests`, and `ContrastFloorTests` key on names). Adding new `--mp-*` tokens is fine.
3. Every top-level const name in the kit must be unique across all JSX files (one shared Babel global scope; prefix per file, like `SL_`). A new mockup file must be registered in `index.html`.
4. Verify by serving `design/` as the static root (the `design-kit` launch config, port 8771) and opening `/ui_kits/macos_app/index.html`. Console clean, light and dark both checked (`prefers-color-scheme` flips the tokens). After editing the CSS, cache-bust the stylesheet before trusting computed styles or screenshots (the static server sends no Cache-Control).
5. Contrast floor: text 4.5:1, large text and UI graphics 3:1, in both modes. The DSN18 CI gate enforces this at port time; a failing pair is a design bug, fix the value now.
6. Copy is load-bearing: keep all labels verbatim unless the prompt names a change. Sentence case, no emoji, no exclamation marks, no em-dashes.
7. **Lock:** the owner eyeballs the rendered kit in both modes, then one commit (`DSN2x: lock <pass>`). The locked mockup is the port spec. The kit is a state gallery and may preview states owned by other tickets; a lock covers the look, not feature scope.

## Run order

| Order | Task | Pass | Gate before next |
|---|---|---|---|
| 1 | DSN20 | Prompt A: Liquid Quiet substrate, all mockups | owner eyeball + lock commit |
| 2 | DSN21 | Prompt B: Instrument capture controls (delta on A) | owner eyeball + lock commit |
| 3 | DSN22 | Prompt C: Library UX upgrades (delta on A) | owner eyeball + lock commit |
| 4-9 | DSN23-DSN28 | Swift ports, one surface band per task | build + tests + rebuild.sh + owner eyeball each |
| 10 | DSN29 | Prompt D: docs + specimen cards + re-sync | docs match shipped reality |

Run A, then B, then C, sequentially: B and C edit files A rewrites. C can start once A is locked (it does not depend on B).

---

## Prompt A (DSN20): lock the Liquid Quiet substrate

Copy-paste from the ruled block:

```
Restyle the meeting-pipe design kit to the "Liquid Quiet" substrate. If you are in the repo, read PRODUCT.md, DESIGN.md, design/README.md, and design/ui_kits/macos_app/README.md first. Mockup-first: touch only design/ (colors_and_type.css + ui_kits/macos_app), no Swift.

Direction. Keep the identity: one teal accent that means capture, coral strictly for the recording dot and destructive confirms, quiet truthful sentence-case copy, no gradients, no emoji. Move the substrate to macOS 26: cool porcelain neutrals, capsule buttons, larger concentric radii, floating chrome as real glass, one type anchor per surface.

Tokens (edit values in colors_and_type.css; never rename an --mp-* variable, adding new ones is fine):
- Light: canvas #F5F6F8, sunk #ECEEF1, raised #FFFFFF; ink #16181C, muted #566068; borders rgba(22,25,29,.10) / strong .16; HUD fill rgba(250,251,252,.78).
- Dark: canvas #1B1D21, raised #26292E, sunk #15161A; fg #F1F2F4, muted #A9B0B8; borders rgba(255,255,255,.09) / strong .16; HUD fill rgba(32,34,38,.78).
- Signal: display 0E9488 light / 36C6B8 dark; fills 0C7F74 in both modes so white labels clear 4.5:1; wash #DFF3F0 light / rgba(54,198,184,.14) dark. Pulse coral unchanged (#E5484D, deep #BE353A for light-mode text; #EF5A5E may serve as the dark dot).
- Radii: keep --mp-radius-xs 4; set --mp-radius-sm to 8 (inputs); cards --mp-radius-md 14; panels --mp-radius-lg 18; --mp-radius-xl 22. Buttons use --mp-radius-full (capsules, 26px tall, 13px side padding).
- Type: chrome stays 13px. One anchor per surface: prompt question 14 semibold, HUD timer 21 semibold tabular, list/pane titles 15, Preferences section headers 17. Content body (summary, transcript) reads at 15. Nothing else inflates.
- Motion: keep 120/180/280ms ease-out; press scales controls to 0.97 over 130ms; keep the 1.6s opacity-only recording pulse; honor prefers-reduced-motion (crossfade or instant).
- Elevation: hairlines still separate resting surfaces inside windows; shadow still means floats; floating chrome (prompt, HUD, dropdown) leans into the hudWindow glass (blur + saturate) with a 0.5px stroke.

Files. Restyle MenuBarDropdown.jsx, MeetingPrompt.jsx, Notification.jsx, PreferencesWindow.jsx, SummaryLibrary.jsx, OnboardingPermissions.jsx to the substrate (structure and labels stay; geometry, tokens, and anchors change). Add RecordingHUD.jsx, missing from the kit, recreated from daemon/Sources/MeetingPipe/RecordingHUDWindow.swift: a 60x162 vertical floating pill (hudWindow glass) with the pulsing coral dot + "Recording" label, the elapsed timer as the 21px anchor, the workflow attribution line, the voice-activity meter, and Stop; include the degraded state (expanded card, "System audio interrupted" banner + Retry) as a second frozen frame. Register the new file in index.html. Keep every top-level const name unique across the kit (prefix them, e.g. HUD_).

Verify. Serve design/ as the static root (port 8771), open /ui_kits/macos_app/index.html: console clean, light and dark both correct, every color routed through --mp-* tokens, text pairs at 4.5:1 (UI 3:1). Cache-bust colors_and_type.css after edits before trusting computed styles.

Done when both modes render clean and the owner has eyeballed and locked. Do not touch Swift.
```

## Prompt B (DSN21): lock the Instrument capture controls

Run only after DSN20 is locked.

```
Layer the "Instrument" control language onto the locked Liquid Quiet kit. Capture surfaces only: MeetingPrompt.jsx, RecordingHUD.jsx, MenuBarDropdown.jsx (recording/idle rows), and the record control + duration numerals in SummaryLibrary.jsx. PreferencesWindow, Notification, Onboarding, and the rest of the Library stay pure Liquid Quiet. Touch only design/, no Swift.

Direction. meeting-pipe's capture moments should feel like recording hardware: controls with machined geometry that answer the hand, an electric on-air accent used like an LED (light, not paint), and mono numerals.

Tokens (add, do not rename):
- New on-air family: --mp-onair-600 #0FBFAC (light) flipping to #2BE3CC (dark), derived from the signal hue. Usage is light-emitting elements only: meter segments, state dots, the record-key ring, the active waveform and playhead on capture surfaces. Buttons, selection, and links keep the signal tokens; the One Signal budget still holds.
- Dark-mode primary record action reads backlit: fill #0FA392 with a near-black label #062A25. Light mode keeps the 0C7F74 fill with a white label.

Controls:
- Record key: a 40px circular key replacing the text Record button on the prompt and the Library toolbar; concentric on-air ring inset 5px at 1.5px, coral disc core; press = 1.5px downward travel + ring compress over 100ms; the disc becomes a rounded square while recording (stop affordance), with a text label beside the key so the state is never color-only.
- Toggles: 36x21 with a 90ms mechanical snap.
- Meters: discrete LED segments (3px bars, 2px gap) in on-air, replacing smooth bars, stepping rather than sliding.
- Numerals: every timecode, duration, count, and the HUD timer set in --mp-font-mono tabular; the HUD timer grows to 24px and is the surface anchor.
- Motion: mechanical, 90-140ms ease-out, no springs; the 1.6s opacity pulse stays; honor prefers-reduced-motion.

Verify and lock exactly as pass A (serve design/ on 8771, console clean, both modes, tokens only, contrast floor, cache-bust). Update the frozen state frames that show recording and prompting. Done when the owner has eyeballed and locked. Do not touch Swift.
```

## Prompt C (DSN22): lock the Library UX upgrades

Run only after DSN20 is locked (independent of B). Source: the 2026-07-05 Library audit. Its functional half (data flags, scope membership, sidecar parsing) is backlog task UX15; this pass designs the states so the port renders them.

```
Apply the Library UX upgrades to the locked Liquid Quiet SummaryLibrary.jsx (and its frozen state frames). Design-only, no Swift. Keep the three-pane structure, the three detail tabs (Summary / Transcript / Audio), Corrections as a sheet, click-to-rename, and the teaching empty states: those audited well.

Changes, each rendered as a visible state in the gallery:
1. Triage actions dominate. Inline fix buttons on rows (Retry / Publish / Republish / Reveal bundle) tint by action: signal fill for publish-shaped actions, coral-outlined for Retry. Today they are grey and vanish into the row.
2. Needs-you grows two members. Design row + scope-count treatment for "Partial" (one sink failed) and "No speech / Unclear audio" appearing in the Needs you scope, and update its empty-state copy to name all five member states.
3. One verb for paste-pending. The list row's inline action reads "Reveal bundle" to match the detail header (today the list says Regenerate, the detail says Reveal bundle); add a hover tooltip: "Long meeting: transcript bundled for manual summarize."
4. Publish failures explain themselves. The detail header's publish-state line carries the short failure reason inline ("Last publish to Notion failed: <reason from the error sidecar>"), and the NDA variant's "Publish anyway..." becomes a real secondary button, not a text link.
5. Reprocess is findable. Add "Reprocess..." to the header actions menu (between Edit summary and Corrections...); restyle the summary-foot bar as a proper secondary control (solid hairline, leading refresh glyph), kept as the in-context entry.
6. Edited meetings are marked. A small pencil glyph after the title on rows whose meeting has a correction record, tooltip "Summary edited locally"; also shown as a caption line in the detail header.
7. The rail gets an INSIGHTS group. Facts and Ask move under their own uppercase section header (they are projections that replace the list, not filters); LIBRARY and WORKFLOWS keep their groups. Judge placement (between or after) in the mockup.
8. Local only reads as intent, not failure. Re-voice the NDA pill: lock glyph + "Kept local", neutral-signal tone, tooltip "On this Mac by design (NDA workflow)". It must not sit visually next to Failed/Unpublished as a sibling problem.
9. Arrivals from Facts/Ask carry context. When a Facts or Ask row opens a meeting, the detail header shows a small dismissible context line ("Opened from Facts"), since the scope snaps to All meetings.
10. Transcript editing is discoverable. One quiet caption under the Transcript tab header: "Click a line to edit or seek."; pointer cursor on line hover.
11. Batch degrades gracefully. A zero-selection batch state that returns to "Select a meeting" instead of an empty batch pane.

Verify and lock exactly as pass A. Done when each numbered change is visible as a state in the gallery, both modes are clean, and the owner has eyeballed and locked. Do not touch Swift.
```

## Prompt D (DSN29): docs, specimen cards, re-sync

Run after the ports (DSN23-DSN28) so the docs describe shipped reality.

```
Close the 2026-07 redesign loop. (a) Rewrite DESIGN.md so the named rules match the shipped system per design/REDESIGN.md "Amended DESIGN.md rules" (retired warm paper, capsule buttons, one-anchor-per-surface, 0.97 press, the Instrument capture-surface exceptions, the new on-air token family), keeping the unchanged rules verbatim. (b) Update design/README.md's visual-foundations narrative to match. (c) Regenerate the specimen cards in design/preview/ (colors, type, buttons, form controls, status pills, elevation, radii, iconography) from the new tokens. (d) Align PRODUCT.md design-principle wording where it names the old look (paper-warm canvas). (e) Re-sync the design/ folder to the Claude Design project so the Design System pane matches. No em-dashes anywhere; sentence case; keep the voice rules untouched.
```

## Port map (DSN23-DSN28)

Each is one `/tech-task` session, one commit. Every task verifies: `swift build` + `swift test` green, `./scripts/rebuild.sh`, owner eyeballs both modes (the daemon is not screenshotable; eyes are the gate), DSN18 token + contrast gates green.

| Task | Scope | Absorbs | Depends on |
|---|---|---|---|
| DSN23 | Port tokens: `Design/Tokens.swift` values to the locked CSS, re-pin `ContrastFloorTests` pair by pair, migrate the ~135 `.system(size:)` literals to `MPType` (load-bearing: the ramp changed) | DSN3 (literal half) | DSN20-22 locked |
| DSN24 | Control kit: MPButton capsule geometry, RecordKey, LED meter, mechanical toggle, MPSurface card primitive + per-theme overlay token | DSN19; DSN3 (one-button-language half, with the named record-key exception) | DSN23 |
| DSN25 | Prompt panel + recording HUD to the locked mockups; build against the macOS 26 SDK (keep the macOS 14 floor); glass on floating chrome only (HUD, prompt, QuickFind), never content | DSN15 (SDK sign-off folds in here) | DSN24 |
| DSN26 | Menu bar item + dropdown states | | DSN24 |
| DSN27 | Library: chrome + the DSN22 UX changes + a11y hardening (VoiceOver labels on status pills, keyboard focus for inline fix buttons) | | DSN24; pairs with UX15 |
| DSN28 | Preferences: PreferencesControls + panes retune against rendered pixels | DSN9 | DSN24. WF6 sequences after this so the WorkflowEditor lands on the new primitives once |

## Functional siblings (not design passes)

- **UX15 (P1), Library triage honesty:** Needs-you scope membership grows to include `.partial` and `.empty`; the library scan computes a has-corrections flag the row and header render; the publish-failure reason is parsed from the error sidecar into the detail-header model; paste-pending uses the single verb in list and detail. Files named in the 2026-07-05 audit (LibraryScope / MeetingStore / MeetingLibraryService / MeetingRow / MeetingDetailView+Header).
- **UX16 (P2), one search story:** decided 2026-07-05: merge. Quick Find becomes the single search, backed by a SQLite FTS5 index over full transcripts + summaries; the filter bar keeps its chips and feeds the same index. Spec in the Q5 backlog. After DSN27.
