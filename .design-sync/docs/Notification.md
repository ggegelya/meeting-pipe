---
category: Surfaces
---
A macOS notification banner (360px) for the recording lifecycle: started, processing, done (with "Open in Notion" action), or error.
`kind` fills sensible default title/body/action; override any of them with `title`, `body`, `action`. Recording filenames render in mono automatically for `started` and `processing`.
Note the export name shadows the browser's Notification API inside the namespace only; usage is unaffected.

```jsx
<Notification kind="done" />
<Notification kind="error" body="Notion publish failed (401)" />
```
