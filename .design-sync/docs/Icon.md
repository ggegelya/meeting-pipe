---
category: Icons
---
The kit's shared icon set: Lucide-style 1.5px-stroke glyphs on a 24px grid, drawn with currentColor (SF Symbols is canonical in the Swift app; these are the web stand-ins).
`name` is a fixed union of about 46 glyphs (mic, waveform, waveform-circle, settings, folder, check-circle, alert-triangle, search, play, pause, stop, chevron-right, chevron-down, lock, calendar, tag, plus, pencil, trash, x, logomark, and more; see the props contract for the full list). `size` sets both dimensions (default 16). Color it via the parent's CSS `color`.
Unknown names render nothing, so stick to the union.

```jsx
<span style={{ color: "var(--mp-fg-subtle)", display: "flex" }}><Icon name="waveform" size={14} /></span>
```
