import { PWToggle } from 'meeting-pipe-design';

// Both states side by side: signal fill when on, ink-300 track when off.
export const OnAndOff = () => (
  <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
    <PWToggle on />
    <PWToggle />
  </div>
);
