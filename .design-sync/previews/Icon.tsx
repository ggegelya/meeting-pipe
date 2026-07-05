import { Icon } from 'meeting-pipe-design';

// Every case in the Icons.jsx switch, in source order.
const GLYPHS = [
  'mic', 'waveform', 'waveform-circle', 'settings', 'sliders', 'cpu', 'plug', 'shield',
  'command', 'folder', 'file-text', 'monitor', 'book', 'check-circle', 'circle', 'seal-check',
  'checklist', 'help-bubble', 'message', 'users', 'alert', 'alert-triangle', 'search', 'play',
  'pause', 'stop', 'external', 'chevron-right', 'chevron-down', 'lock', 'user', 'tray',
  'calendar', 'tag', 'plus', 'pencil', 'more', 'more-circle', 'gauge', 'eye', 'eye-off',
  'stethoscope', 'refresh', 'bell', 'trash', 'x', 'logomark',
] as const;

// The full set, each glyph named.
export const AllGlyphs = () => (
  <div style={{ display: 'flex', flexWrap: 'wrap', gap: 2, maxWidth: 560, color: 'var(--mp-fg)' }}>
    {GLYPHS.map((n) => (
      <div key={n} style={{ width: 66, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 5, padding: '8px 2px' }}>
        <Icon name={n} size={16} />
        <div style={{ fontSize: 9, color: 'var(--mp-fg-muted)', fontFamily: 'var(--mp-font-sans)', textAlign: 'center', lineHeight: 1.2 }}>{n}</div>
      </div>
    ))}
  </div>
);

// One glyph across the size ramp.
export const Sizes = () => (
  <div style={{ display: 'flex', alignItems: 'flex-end', gap: 20, color: 'var(--mp-fg)' }}>
    {([12, 16, 24, 32] as const).map((s) => (
      <div key={s} style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6 }}>
        <Icon name="waveform" size={s} />
        <div style={{ fontSize: 9, color: 'var(--mp-fg-subtle)', fontFamily: 'var(--mp-font-mono)' }}>{s}</div>
      </div>
    ))}
  </div>
);

// Icons stroke with currentColor, so a wrapping span sets the tint.
export const Tinted = () => (
  <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
    <span style={{ color: 'var(--mp-signal-600)', display: 'flex' }}><Icon name="waveform-circle" size={20} /></span>
    <span style={{ color: 'var(--mp-success-600)', display: 'flex' }}><Icon name="check-circle" size={20} /></span>
    <span style={{ color: 'var(--mp-danger-600)', display: 'flex' }}><Icon name="alert-triangle" size={20} /></span>
  </div>
);
