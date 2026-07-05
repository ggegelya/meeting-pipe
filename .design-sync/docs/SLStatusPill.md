---
category: Controls
---
The Library's meeting-status pill: `status` picks tint, label, and marker (ready, recording with pulsing dot, processing, paste, failed, partial, unpublished, local).
This is the canonical status vocabulary of the app; prefer it over inventing new badges.

```jsx
<SLStatusPill status="ready" /> <SLStatusPill status="recording" /> <SLStatusPill status="failed" />
```
