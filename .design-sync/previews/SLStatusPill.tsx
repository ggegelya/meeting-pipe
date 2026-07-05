import { SLStatusPill } from 'meeting-pipe-design';

// The full status vocabulary of the Library, one pill per state.
export const AllStatuses = () => (
  <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8, alignItems: 'center', maxWidth: 420 }}>
    <SLStatusPill status="ready" />
    <SLStatusPill status="recording" />
    <SLStatusPill status="processing" />
    <SLStatusPill status="paste" />
    <SLStatusPill status="failed" />
    <SLStatusPill status="partial" />
    <SLStatusPill status="unpublished" />
    <SLStatusPill status="local" />
  </div>
);

// How a pill sits next to a meeting title in a list row.
export const InListRow = () => (
  <div style={{ display: 'flex', alignItems: 'center', gap: 10, fontFamily: 'var(--mp-font-sans)', color: 'var(--mp-fg)', fontSize: 'var(--mp-text-base)' }}>
    <span style={{ fontWeight: 500 }}>Release planning</span>
    <span style={{ color: 'var(--mp-fg-subtle)', fontSize: 'var(--mp-text-sm)' }}>Zoom · 42 min</span>
    <SLStatusPill status="ready" />
  </div>
);
