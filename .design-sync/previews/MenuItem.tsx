import { MenuItem, MenuSep } from 'meeting-pipe-design';

// Opaque stand-in for the dropdown's translucent column.
const menu = {
  width: 240,
  background: 'var(--mp-bg-raised)',
  border: '1px solid var(--mp-border)',
  borderRadius: 8,
  padding: 4,
  fontFamily: 'var(--mp-font-sans)',
  fontSize: 'var(--mp-text-base)',
  color: 'var(--mp-fg)',
} as const;

// The idle menu, item by item. Hover paints signal-600; that is interaction-only.
export const FullMenu = () => (
  <div style={menu}>
    <MenuItem header>MeetingPipe: Idle</MenuItem>
    <MenuSep />
    <MenuItem>Start Recording</MenuItem>
    <MenuSep />
    <MenuItem shortcut="⌘,">Preferences…</MenuItem>
    <MenuItem shortcut="⌘Q">Quit MeetingPipe</MenuItem>
  </div>
);

// A disabled mono file row next to a normal item with a shortcut.
export const States = () => (
  <div style={menu}>
    <MenuItem disabled mono>20260705-1030.wav</MenuItem>
    <MenuItem shortcut="⌘,">Preferences…</MenuItem>
  </div>
);
