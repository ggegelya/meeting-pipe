import { PWField } from 'meeting-pipe-design';

const card = {
  background: 'var(--mp-bg)',
  padding: 16,
  borderRadius: 10,
  display: 'inline-flex',
  gap: 8,
  alignItems: 'center',
} as const;

// Plain text value at the default 13px.
export const TextValue = () => (
  <div style={card}>
    <PWField value="Weekly sync notes" />
  </div>
);

// Mono path at a fixed width, as the recordings folder row uses it.
export const MonoPath = () => (
  <div style={card}>
    <PWField value="~/Recordings" mono width={200} />
  </div>
);

// Placeholder only, the BYO endpoint field before anything is entered.
export const Placeholder = () => (
  <div style={card}>
    <PWField placeholder="https://api.anthropic.com" mono width={260} />
  </div>
);
