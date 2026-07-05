import { SLEmpty } from 'meeting-pipe-design';

const wrap: React.CSSProperties = { width: 430, height: 320, fontFamily: 'var(--mp-font-sans)', color: 'var(--mp-fg)', background: 'var(--mp-bg)', borderRadius: 10 };

// The attention filter with nothing to show.
export const NeedsAttention = () => (
  <div style={wrap}>
    <SLEmpty icon="tray" title="Nothing needs attention" body="Failed or unpublished meetings would appear here." />
  </div>
);

// Search came back empty, with a way out.
export const NoResults = () => (
  <div style={wrap}>
    <SLEmpty icon="search" title="No matches" body="Try a different query or clear the filters." action="Clear filters" />
  </div>
);
