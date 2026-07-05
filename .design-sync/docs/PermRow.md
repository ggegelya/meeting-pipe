---
category: Structure
---
One permission row: icon tile, `name` + `why` explanation, and either a green Granted check (`state="granted"`) or a grant button (`state="needed"`, label from `cta`, default "Grant").
The `why` copy should say concretely what the permission enables, in the product's plain, privacy-forward voice.

```jsx
<PermRow icon="mic" name="Microphone" why="Captures your voice via AVAudioEngine." state="granted" />
<PermRow icon="monitor" name="Screen Recording" why="Captures system audio. We don't record video." state="needed" cta="Open System Settings" />
```
