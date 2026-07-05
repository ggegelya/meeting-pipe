---
category: Controls
---
A static slider row: filled track proportional to `value`/`max`, with the formatted value (`format`, e.g. "30 s" or "0.6") right-aligned in mono at `valueWidth` px (default 56).
Renders as fragments meant to sit inside a stacked preference row that provides the label.

```jsx
<PWSlider value={30} max={120} format="30 s" />
```
