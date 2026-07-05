import { SLActionItem, SLBullets, SLSection, SLSegmented } from 'meeting-pipe-design';

const wrap: React.CSSProperties = { width: 430, fontFamily: 'var(--mp-font-sans)', color: 'var(--mp-fg)', background: 'var(--mp-bg)', padding: 16, borderRadius: 10 };

// Section holding action items, the way the reader composes it.
export const ActionItems = () => (
  <div style={wrap}>
    <SLSection icon="checklist" title="Action items">
      <SLActionItem task="Draft the migration runbook" owner="Georgy" due="Jul 10" confidence="high" />
      <SLActionItem task="Share the summary with the team" owner="Georgy" />
    </SLSection>
  </div>
);

// Section holding plain bullets.
export const Decisions = () => (
  <div style={wrap}>
    <SLSection icon="seal-check" title="Decisions">
      <SLBullets items={[
        'Keep the recorder on the 48 kHz wav default.',
        'Publish to Notion only after a manual review.',
      ]} />
    </SLSection>
  </div>
);

// The right slot carries a control, here a read/edit switch.
export const WithRightSlot = () => (
  <div style={wrap}>
    <SLSection icon="book" title="Summary" right={<SLSegmented options={['Read', 'Edit']} selected={0} />}>
      <SLBullets items={[
        'Q3 scope agreed: ship the roster editor first.',
        'Pricing review moves to Thursday.',
      ]} />
    </SLSection>
  </div>
);
