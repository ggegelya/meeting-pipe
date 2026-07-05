import { PermRow } from 'meeting-pipe-design';

// Permission already granted: quiet check, no button.
export const Granted = () => (
  <div style={{ width: 460, fontFamily: 'var(--mp-font-sans)', color: 'var(--mp-fg)', background: 'var(--mp-bg)', padding: 12, borderRadius: 10 }}>
    <PermRow icon="mic" name="Microphone" why="Captures your voice via AVAudioEngine." state="granted" />
  </div>
);

// Still needed, with a custom call to action.
export const NeededWithCta = () => (
  <div style={{ width: 460, fontFamily: 'var(--mp-font-sans)', color: 'var(--mp-fg)', background: 'var(--mp-bg)', padding: 12, borderRadius: 10 }}>
    <PermRow icon="monitor" name="Screen Recording" why="Captures system audio via ScreenCaptureKit. We don't record video." state="needed" cta="Open System Settings" />
  </div>
);

// Both states stacked, as the onboarding step lays them out.
export const Stack = () => (
  <div style={{ width: 460, fontFamily: 'var(--mp-font-sans)', color: 'var(--mp-fg)', background: 'var(--mp-bg)', padding: 12, borderRadius: 10, display: 'flex', flexDirection: 'column', gap: 8 }}>
    <PermRow icon="mic" name="Microphone" why="Captures your voice via AVAudioEngine." state="granted" />
    <PermRow icon="monitor" name="Screen Recording" why="Captures system audio via ScreenCaptureKit. We don't record video." state="needed" cta="Open System Settings" />
  </div>
);
