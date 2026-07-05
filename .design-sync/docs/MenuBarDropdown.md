---
category: Surfaces
---
The menu-bar dropdown (240px wide) mirroring the daemon's status menu in its idle / recording / prompting states.
`state` swaps the header line and the primary action: `idle` shows "Start Recording", `recording` shows the pulsing stop row plus the current `file` name in mono, `prompting` names the detected `source`. The rest of the menu (logs, recordings, Preferences, Quit) is fixed.
Compose it directly under a menu-bar mockup; it already carries the HUD blur, border, and shadow.

```jsx
<MenuBarDropdown state="recording" file="20260705-1030.wav" />
```
