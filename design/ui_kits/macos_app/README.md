# Meeting Pipe — macOS App UI Kit

HTML/JSX recreations of the shipped Swift menu-bar daemon's surfaces, faithful to structure, labels, layout, and the design tokens. These are mockups for design exploration, not real AppKit code.

The kit covers the surfaces that ship today, plus one anticipated near-future surface (onboarding):

| Component | Maps to | Source of truth |
|---|---|---|
| `MenuBarDropdown.jsx` | `StatusBarController.swift` | the `rebuildMenu()` function |
| `MeetingPrompt.jsx` | `MeetingPromptWindow.swift` | the 600×64 horizontal `NSPanel` pill + the `⌄` chevron menu |
| `Notification.jsx` | `Notifier.swift` | `notifyDone` / `notifyRecordingStarted` body strings |
| `PreferencesWindow.jsx` | `Preferences/PreferencesView.swift` + the per-section files | the 780×660 `NavigationSplitView` (General / Recording / Prompt / Pipeline / Integrations / Permissions / Advanced) |
| `SummaryLibrary.jsx` | `LibraryWindow.swift` + `LibrarySidebar` / `LibraryListView` / `MeetingRow` / `MeetingDetailView` + tabs | the shipped `NavigationSplitView` Library (rail + filtered list + Summary / Transcript / Audio tabs) |
| `OnboardingPermissions.jsx` | *(anticipated)* | the four-permission grant list (Microphone, Screen Recording, Accessibility, Notifications); see the README install steps |

`index.html` shows them composed against a faux desktop so you can see how the
menu bar, dropdown, and prompt sit on screen together.

## Caveats specific to this kit
- The `SummaryLibrary` and `PreferencesWindow` mockups draw a light window chrome (border, radius, shadow) inline; the real app uses native `NSWindow`. The `macos_window.jsx` starter stays available for framing screenshots.
- Tabs and panes are interactive in the mockups (the Library detail tabs, the Preferences sidebar) so a reviewer can click through; the real app persists those selections.
- Translucency: real `NSVisualEffectView .hudWindow` blends with whatever is behind it on the desktop. Web `backdrop-filter` only blends with what is in the page, which is close enough for design review.
- Only `OnboardingPermissions` is still a proposed design rather than a faithful recreation of shipped code. Every other surface in this kit mirrors a surface that ships today, faithful to structure, labels, and tokens (not byte-identical to AppKit).
- Known lag from UX22 (not yet re-mocked; a rendered eyeball is owner-owed): `MenuBarDropdown` does not show the new **"Finish setup"** checklist row (a submenu of unmet setup items that appears until everything is green), and the onboarding flow gained a **"Where summaries go"** publish-target step (Notion token + database picker + a read-only Verify) between the workflow and test steps. Update these when the surfaces are next re-mocked from screenshots.
