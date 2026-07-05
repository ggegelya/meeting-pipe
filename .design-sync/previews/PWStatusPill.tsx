import { PWStatusPill } from 'meeting-pipe-design';

// The four tones the permissions pane speaks in.
export const AllTones = () => (
  <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap', fontFamily: 'var(--mp-font-sans)' }}>
    <PWStatusPill tone="granted" icon="check-circle" text="Granted" />
    <PWStatusPill tone="needed" icon="alert" text="Needs access" />
    <PWStatusPill tone="denied" icon="x" text="Denied" />
    <PWStatusPill tone="neutral" icon="circle" text="Not configured" />
  </div>
);
