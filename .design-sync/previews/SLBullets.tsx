import { SLBullets } from 'meeting-pipe-design';

const wrap: React.CSSProperties = { width: 430, fontFamily: 'var(--mp-font-sans)', color: 'var(--mp-fg)', background: 'var(--mp-bg)', padding: 16, borderRadius: 10 };

// Plain bullets, one takeaway per line.
export const Takeaways = () => (
  <div style={wrap}>
    <SLBullets items={[
      'Q3 scope agreed: ship the roster editor first.',
      'Pricing review moves to Thursday.',
      'Marketing site copy is blocked on the rename.',
    ]} />
  </div>
);

// Numbered variant: mono digits replace the dot.
export const Numbered = () => (
  <div style={wrap}>
    <SLBullets numbered items={[
      'Defer the audit-log refactor to the next release.',
      'Keep the staging runner pinned until the clock fix lands.',
      'Move the retro to Friday morning.',
    ]} />
  </div>
);
