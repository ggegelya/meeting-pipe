# Meeting Pipe — macOS App UI Kit

Pixel-faithful HTML/JSX recreations of the existing Swift menu-bar daemon's
surfaces. These are mockups for design exploration — not real AppKit code.

The kit covers the four surfaces that exist today plus two anticipated
near-future surfaces:

| Component | Maps to | Source of truth |
|---|---|---|
| `MenuBarDropdown.jsx` | `StatusBarController.swift` | the `rebuildMenu()` function |
| `MeetingPrompt.jsx` | `MeetingPromptWindow.swift` | the 380×180 `NSPanel` content view |
| `Notification.jsx` | `Notifier.swift` | `notifyDone` / `notifyRecordingStarted` body strings |
| `PreferencesWindow.jsx` | `Preferences/PreferencesView.swift` | the SwiftUI split view (General / Recording / Prompt / Pipeline / Integrations / Permissions / Advanced) |
| `SummaryLibrary.jsx` | *(anticipated)* | derived from filename patterns + Notion summary schema |
| `OnboardingPermissions.jsx` | *(anticipated)* | the four-permission grant list (Microphone, Screen Recording, Accessibility, Notifications); see the README install steps |

`index.html` shows them composed against a faux desktop so you can see how the
menu bar, dropdown, and prompt sit on screen together.

## Caveats specific to this kit
- We mock the macOS chrome with the `macos_window.jsx` starter component for
  the Preferences window. The real app uses native `NSWindow`.
- Translucency: real `NSVisualEffectView .hudWindow` blends with whatever's
  behind it on the desktop. Web `backdrop-filter` only blends with what's in
  the page — close enough for design review.
- The `SummaryLibrary` and `OnboardingPermissions` surfaces don't exist in
  code yet. They are proposed designs derived from the spec, not faithful
  recreations.
