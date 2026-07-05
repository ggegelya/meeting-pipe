import { PWTag } from 'meeting-pipe-design';

// Skip keywords as removable mono chips.
export const Keywords = () => (
  <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
    <PWTag>standup</PWTag>
    <PWTag>focus block</PWTag>
    <PWTag>1:1</PWTag>
  </div>
);
