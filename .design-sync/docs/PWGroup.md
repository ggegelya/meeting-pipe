---
category: Structure
---
The preferences settings group: uppercase `label` above a raised, bordered card of rows, with an optional `footer` caption below.
Children are PWRow-family rows; the first row passes `first` to drop its top hairline.

```jsx
<PWGroup label="Recording" footer="Files land in ~/Recordings.">
  <PWRow label="Launch at login" first><PWToggle on /></PWRow>
  <PWRow label="Format"><PWSegmented options={["wav", "flac"]} selected={0} /></PWRow>
</PWGroup>
```
