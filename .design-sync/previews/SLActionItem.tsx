import { SLActionItem } from 'meeting-pipe-design';

const wrap: React.CSSProperties = { width: 430, fontFamily: 'var(--mp-font-sans)', color: 'var(--mp-fg)', background: 'var(--mp-bg)', padding: 16, borderRadius: 10 };

// Everything on: owner, due date, and the high-confidence chip.
export const Full = () => (
  <div style={wrap}>
    <SLActionItem task="Send the revised estimate to the client" owner="Georgy" due="Jul 8" confidence="high" />
  </div>
);

// Task only, no chips.
export const Minimal = () => (
  <div style={wrap}>
    <SLActionItem task="Confirm the room booking for the offsite" />
  </div>
);

// A short list with varying chip combinations.
export const List = () => (
  <div style={wrap}>
    <SLActionItem task="Send the revised estimate to the client" owner="Georgy" due="Jul 8" confidence="high" />
    <SLActionItem task="Book the follow-up call with the vendor" owner="Georgy" />
    <SLActionItem task="Update the onboarding checklist" due="Jul 12" />
  </div>
);
