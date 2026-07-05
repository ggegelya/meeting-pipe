---
category: Surfaces
---
The record-this-meeting pill: a 600x64 horizontal HUD shown when a meeting is detected, with app glyph, live mic waveform, workflow chip, and the Record / Record (BYO) action cluster.
Use it as the hero surface for detection-flow mockups. `source.displayName` picks the app glyph (Zoom, Microsoft Teams, Google Meet, Slack; anything else gets the fallback glyph) and fills the uppercase eyebrow. `workflow` renders the colored chip (pass `null` to hide). A 2px hairline along the bottom drains over `timeoutSec` (auto-dismiss, pauses on hover) and the 4-bar waveform animates from simulated mic levels.
Place it over a desktop-style background; it is a floating translucent pill (hudWindow blur), not an in-window card.

```jsx
<MeetingPrompt source={{ displayName: "Microsoft Teams" }} workflow={{ name: "1:1s", color: "var(--mp-warning-600)" }} timeoutSec={30} />
```
