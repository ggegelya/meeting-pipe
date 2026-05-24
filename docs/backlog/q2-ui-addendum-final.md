# MeetingPipe UI addendum

These ten tasks address Tier 1 UI gaps visible in the May 2026 UI screenshots. They are parallel-safe (each touches a separate view file) and small (each is S unless noted). Add to `meetingpipe-q2-backlog.md` under a new Group UI, or execute standalone. They do not depend on Phase 0 or Phase 1 work and can land in any order alongside other parallel-safe tasks.

The voice and format match the existing backlog. No em-dashes. Each task is self-contained for one Claude Code session.

---

## Group UI · Quick-win polish

**TECH-UI-1 · App icon column in meeting list rows · S · none** [NEW]

The meeting list row currently shows the bundle-id text truncated as `Mic...` followed by duration and workflow chip. Replace the truncated bundle-id text with the meeting app's icon, rendered at 16x16 (the standard Apple HIG menu-row size). Source the icon from `NSWorkspace.shared.icon(forFile:)` when the app bundle is available locally; fall back to a generic SF Symbol (`video.fill` for native apps, `safari.fill` for browser-hosted meetings) when the bundle cannot be resolved (older recordings whose source app has been uninstalled).

Edit: the SwiftUI row view used for meeting list rows under `Sources/MeetingPipeLibrary/Views/` (probable filename: `MeetingListRowView.swift`; locate by `grep -r "Mic\." Sources/`).

Acceptance:
- Recordings from Teams, Zoom, Meet (Chrome and Arc), and Webex render the app's official icon in the row.
- Truncated bundle-id text is gone.
- Row vertical alignment unchanged (icon sits in the same vertical band as the old text).
- The icon has a `.help(_:)` modifier showing the human-readable app name on hover.

Stop and ask: if `NSWorkspace.shared.icon(forFile:)` cannot resolve an icon for a user-relevant app (Webex unified vs legacy bundle ID, browser PWAs for Meet/Slack), document the failed cases and propose a fallback strategy before shipping.

Deps: none.

---

**TECH-UI-2 · UI string em-dash audit and CI guard · S · none** [NEW]

Audit all `.strings` catalog files plus all Swift string literals that surface in the UI for em-dashes (U+2014). Replace with hyphens, commas, or rewrites per the project's no-em-dash convention. The string `No rules — this workflow matches only when used as the default.` in the workflow editor is the example surfaced from screenshots; assume more exist.

Extend the existing pre-commit em-dash check to also cover `.strings` catalogs and Swift string literals (not just comments). Add a CI lint step that fails the build if any `.swift`, `.strings`, or `.stringsdict` file under `Sources/` or `Resources/` contains U+2014.

Edit: `.github/workflows/lint.yml` (or the equivalent CI workflow file); any `.strings` and `.swift` files containing em-dashes.

Acceptance:
- `git grep -l $'\u2014' Sources Resources` returns no Swift, .strings, or .stringsdict files.
- CI lint catches a deliberately-added em-dash in a throwaway branch.
- The workflow editor's matching-rules helper text no longer contains an em-dash; replacement reads `No rules - this workflow matches only when used as the default.` or rewrite.

Deps: none.

---

**TECH-UI-3 · Workflow color drives pill color · S · none** [NEW]

Workflow chips (the `General` badge in list rows and the chip above the detail-pane title) currently render with a hardcoded system-blue background regardless of the workflow's configured color. Pills should derive their visual tint from the workflow's own color (the `#3478F` hex stored on the `Workflow` model). Use a low-opacity tint for the background (alpha 0.18) and the workflow color at full opacity for the text. Fall back to system blue if the workflow has no color set.

Edit: the SwiftUI view that renders workflow chips (probable location: `Sources/MeetingPipeLibrary/Views/WorkflowChip.swift` or `Sources/MeetingPipe/Views/WorkflowChip.swift`; locate by grep for `General` background color).

Acceptance:
- A workflow with a red color renders the pill with a red tint and red text.
- A workflow with no color set falls back to system blue.
- Contrast against the dark background meets WCAG AA for a sample palette spanning red, green, blue, orange, purple.
- The workflow color dot in the sidebar continues to render at full opacity (do not tint that).

Stop and ask: if any workflow color produces poor contrast against the dark background, document the failed colors and propose either a minimum-saturation rule on the color picker or a contrast-aware text-color fallback (white text on darker tints).

Deps: none.

---

**TECH-UI-4 · Detected language in metadata row · S · none** [NEW]

The `Detected language: en` text currently sits as a standalone line at the bottom of the summary section, visually orphaned. Move it into the detail-pane metadata row between the duration and the meeting-app name. Render the language code uppercase in a small monospaced font, slightly dimmed (secondary label color), with a tooltip showing the full language name (`English`, `Deutsch`, etc).

Edit: the detail-pane summary view (probable: `Sources/MeetingPipeLibrary/Views/MeetingDetailSummaryView.swift`); the metadata row header (probable: `Sources/MeetingPipeLibrary/Views/MeetingDetailHeaderView.swift`).

Acceptance:
- Detail header reads: `14 May 2026 at 10:54 · 0:31 · EN · Microsoft Teams`.
- Hovering the `EN` shows tooltip `English`.
- The bottom of the summary no longer contains `Detected language: en`.
- When language is unknown, the chip is hidden entirely (not rendered as empty).

Deps: none.

---

**TECH-UI-5 · Inline title rename plus toolbar menu · M · none** [NEW]

The `Edit` button at the bottom-right of the detail pane is replaced by two affordances closer to the content:

1. Click-to-rename on the title text. Single click positions a text field over the title; Return commits, Escape cancels. The field uses the same font and size as the title to avoid layout jitter.
2. A `...` menu button added to the detail-pane top toolbar (right side, next to the existing external-link and folder icons). The menu exposes the actions that were previously gated by the bottom `Edit` button: Edit summary, Edit transcript, Reprocess, Delete, Open meta.json, Copy meeting ID. Locate the existing action list by reading the bottom-Edit button's current handler.

Edit: `Sources/MeetingPipeLibrary/Views/MeetingDetailView.swift` (probable path); remove the bottom-right `Edit` button entirely.

Acceptance:
- Clicking the title positions an editable text field; Return commits and persists the rename to the sidecar JSON; Escape cancels.
- The toolbar `...` button opens a popover menu with all the previously-available actions.
- The bottom-right `Edit` button is gone.
- Keyboard shortcut: pressing Return when the meeting is selected and no field is focused puts focus on the title-rename field.
- The toolbar menu items each emit a `Log.event("detail.toolbar.action", ...)` event for audit traceability.

Stop and ask: if any existing functionality from the old `Edit` button does not map onto the new affordances (rare but possible — list the orphaned actions before deleting the old button).

Deps: none.

---

**TECH-UI-6 · Detail-pane toolbar tooltips · S · none** [NEW]

The two icons at the top-right of the detail pane (external-link arrow, folder) currently render with no tooltip or accessibility label. The external-link icon opens the meeting in the configured external sink (Notion / Obsidian / filesystem); the folder icon opens the recording's raw-files directory in Finder. Add `.help(_:)` modifiers and `.accessibilityLabel(_:)` to both. The external-link tooltip dynamically reflects the current sink name.

Edit: `Sources/MeetingPipeLibrary/Views/MeetingDetailView.swift` (the toolbar row, likely the same file modified in TECH-UI-5; coordinate to avoid merge conflict if running in parallel).

Acceptance:
- External-link icon shows tooltip `Open in Notion` (or `Open in Obsidian`, `Open files folder` for filesystem) depending on the current sink.
- Folder icon shows tooltip `Show raw files in Finder`.
- Both have `accessibilityLabel` set for VoiceOver. VoiceOver reads the same text as the tooltip.
- When the meeting has no resolved sink, the external-link icon is hidden (not rendered with a missing tooltip).

Deps: none. Coordinate with TECH-UI-5 if both run in parallel.

---

**TECH-UI-7 · Workflow editor modal title reflects name · S · none** [NEW]

The workflow editor modal currently shows `Untitled workflow` as both the modal header text and the name-field placeholder, which makes it ambiguous whether the user is editing a new or existing workflow. The modal header should reflect the current value of the name field live as the user types, falling back to `New workflow` when the field is empty and the workflow is unsaved, or to the saved name when editing an existing workflow. The placeholder text inside the name field remains `Untitled workflow`.

Edit: the workflow editor view (probable: `Sources/MeetingPipe/Views/WorkflowEditorView.swift` or `Sources/MeetingPipeLibrary/Views/WorkflowEditorSheet.swift`; locate by grep for `Untitled workflow`).

Acceptance:
- Opening the editor for a new workflow shows modal header `New workflow`.
- Typing `Pharma calls` into the name field updates the modal header to `Pharma calls` live (no commit needed).
- Opening the editor for an existing workflow named `Pharma calls` shows modal header `Pharma calls` from the start.
- Clearing the field for an existing workflow reverts the header to `New workflow` (the field's placeholder, not the saved name, since the user has visibly cleared it).
- The placeholder inside the empty input field remains `Untitled workflow`.

Deps: none.

---

**TECH-UI-8 · Sidebar zero-count muting · S · none** [NEW]

The sidebar count badges (`72`, `3`, `26`, `0`, etc) currently all render at the same text color. Counts that equal zero should render at a muted color (secondary label color at approximately 50% opacity) to de-emphasize empty filters and workflows. Non-zero counts stay at full secondary label color.

Edit: `Sources/MeetingPipeLibrary/Views/LibrarySidebarView.swift` or the row component that renders the count (probable: a `SidebarRow` view; grep for the count text style).

Acceptance:
- `NDA only 0` and `Untitled workflow 0` in the screenshots render with a dimmed `0`.
- Non-zero counts render at full text color.
- Counts update color live when filter results cross the zero boundary (e.g. if `Today` drops to 0 mid-session).
- The muting applies only to the count, not to the row's icon or label.

Deps: none.

---

**TECH-UI-9 · Relative date formatting in list rows · S · none** [NEW]

The date column in meeting list rows currently shows cramped abbreviations like `Yest 10:54` and `Wed 17:33`. Replace with a `RelativeDateTimeFormatter`-backed format that produces:
- `Today HH:mm` for today.
- `Yesterday HH:mm` for yesterday.
- `Wed HH:mm` (localized weekday abbreviation) for this week, days 2 through 7.
- `14 May HH:mm` for older dates within the current year.
- `14 May 2025` for older than the current year.

The detail-pane metadata row continues to use the absolute format (`14 May 2026 at 10:54`). This task only changes the list row.

Edit: `Sources/MeetingPipeLibrary/Views/MeetingListRowView.swift`; potentially a new helper `Sources/MeetingPipeLibrary/Util/RelativeMeetingDateFormatter.swift` so the same formatter is reusable elsewhere.

Acceptance:
- All five format cases verified manually with seeded fixtures spanning today, yesterday, 3 days ago, 14 days ago, and 18 months ago.
- Format respects the user's locale (verify in en, de, fr by toggling system locale).
- Column width does not jitter when the formatter crosses date boundaries (allocate enough horizontal space for the longest expected case, `14 May 2025` plus a small margin).
- The seconds component is omitted everywhere (HH:mm only).

Deps: none.

---

**TECH-UI-10 · Waveform playback controls regroup · S · none** [NEW]

The playback controls below the waveform currently render `Fit · 1x · 2x · 4x · 8x` as five equal-weight buttons that mix two concepts (playback speed and waveform zoom). Separate them:
- Playback speed becomes a segmented control (`1x | 2x | 4x | 8x`) with the active speed highlighted. Placed on the right side of the playback row, next to the time display.
- Waveform zoom becomes two icon buttons: `Fit to window` (the existing `Fit` semantics, presumably scales the waveform to fill the available width) and `Zoom horizontal` (a new affordance that cycles 1x / 2x / 4x of the horizontal pixel-per-second scale). Both placed near the left of the playback row.

Before refactoring, verify the existing `Fit` button's behaviour by reading the implementation: if `Fit` already means horizontal-fit-to-window, keep that meaning and only add the new `Zoom horizontal` button. If `Fit` means something else (e.g. vertical autoscale), preserve that semantic and add both new zoom controls separately.

Edit: `Sources/MeetingPipeLibrary/Views/PlaybackControlsView.swift`.

Acceptance:
- Speed segmented control highlights the active speed; changing speed updates the audio engine rate and the visible time scrubber.
- `Fit to window` icon resets the waveform horizontal scale to fit the available pane width.
- `Zoom horizontal` icon cycles 1x / 2x / 4x; tooltip shows the current scale (`Zoom horizontal (currently 2x)`).
- All three controls have `.help(_:)` tooltips: `Playback speed`, `Fit to window`, `Zoom horizontal`.
- Existing playback behaviour at default speed and default zoom is byte-identical to pre-refactor (no regression in scrubber position, no regression in audio output).

Stop and ask: if `Fit` currently controls a behaviour other than horizontal fit (verify by reading the existing handler before refactoring), preserve its current meaning and surface the discovered semantic so the new `Zoom horizontal` can be designed alongside it rather than overlapping.

Deps: none.

---

## Parallel safety

All ten tasks touch separate view files except for TECH-UI-5 and TECH-UI-6, which both edit `MeetingDetailView.swift`. Run those two serially or in a coordinated single session.

Wave A (fully parallel, 4 sessions): TECH-UI-1, TECH-UI-2, TECH-UI-3, TECH-UI-4.

Wave B (fully parallel, 4 sessions): TECH-UI-7, TECH-UI-8, TECH-UI-9, TECH-UI-10.

Wave C (serial within wave, 1 session each): TECH-UI-5, then TECH-UI-6.

Total: about 1 to 1.5 days of solo-developer time, achievable in roughly 10 Claude Code sessions over an afternoon if waves A and B are spawned concurrently.

---

## Substitution examples for the Claude Code prompt template

Single task: `TECH-UI-1`

Wave A in parallel (four sessions): each session gets one of `TECH-UI-1`, `TECH-UI-2`, `TECH-UI-3`, `TECH-UI-4`.

Wave A plus B combined: `TECH-UI-1, TECH-UI-2, TECH-UI-3, TECH-UI-4, TECH-UI-7, TECH-UI-8, TECH-UI-9, TECH-UI-10` (eight parallel sessions).

Detail-pane tasks serially: first `TECH-UI-5`, then `TECH-UI-6` after UI-5's commits have landed.

---

## Tier 2 deferred (not in this addendum)

The visual style elevation work is explicitly deferred to a future polish phase. It is not in this addendum and should not be executed until Phase 3 detection polish lands and the app feels solid in daily use. Candidate Tier 2 tasks for that future round:

- Custom accent color replacing system blue, giving MeetingPipe a visual identity distinct from generic Mac apps.
- Refined type scale with variable line height by row density (looser in detail panes, tighter in dense list rows).
- Status pills as small dot + text (Linear style) replacing the current rounded rectangle badges, for refined density at high meeting counts.
- Waveform palette refinement, replacing the high-saturation magenta system-audio color with a deliberate complementary tone (candidate pairings: blue + warm coral, or blue + teal).
- Micro-interaction polish: hover states, focus indicators, button-press transitions, subtle row-selection animation.
- Light-mode parity if the current build is dark-mode-only.

The CLAUDE.md framing is engineering excellence first. Tier 2 is roughly half a fortnight of focused polish work, but should not preempt Phase 0 through Phase 3 progress on the critical path.
