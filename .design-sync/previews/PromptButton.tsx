import { Icon, PromptButton } from 'meeting-pipe-design';

const card = {
  background: 'var(--mp-bg)',
  padding: 16,
  borderRadius: 10,
  display: 'inline-flex',
  gap: 8,
  alignItems: 'center',
} as const;

// The exact cluster from the meeting prompt: BYO, primary Record, overflow chevron.
export const ActionCluster = () => (
  <div style={card}>
    <PromptButton>Record (BYO)</PromptButton>
    <PromptButton primary>Record</PromptButton>
    <PromptButton chevron><Icon name="chevron-down" size={12} /></PromptButton>
  </div>
);

// Primary carries the signal fill; one per prompt.
export const Primary = () => (
  <div style={card}>
    <PromptButton primary>Record</PromptButton>
  </div>
);

// Default sits on the raised surface with a strong hairline.
export const Default = () => (
  <div style={card}>
    <PromptButton>Skip this meeting</PromptButton>
  </div>
);
