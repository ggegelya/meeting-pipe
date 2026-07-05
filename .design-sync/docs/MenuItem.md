---
category: Controls
---
One row of the menu-bar dropdown: label left, optional `shortcut` right in mono, with `header` (bold, inert), `disabled`, and `mono` (filename) variants; hover fills signal-600.
Compose inside a HUD-styled container (see MenuBarDropdown) with MenuSep between groups.

```jsx
<MenuItem header>MeetingPipe: Idle</MenuItem>
<MenuItem shortcut="⌘,">Preferences…</MenuItem>
<MenuItem disabled mono>20260705-1030.wav</MenuItem>
```
