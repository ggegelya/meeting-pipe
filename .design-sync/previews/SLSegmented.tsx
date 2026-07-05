import { SLSegmented } from 'meeting-pipe-design';

const wrap = { fontFamily: 'var(--mp-font-sans)', color: 'var(--mp-fg)', display: 'inline-flex' } as const;

// The Library's Read/Edit mode switch, Read active.
export const ReadEdit = () => (
  <div style={wrap}>
    <SLSegmented options={['Read', 'Edit']} selected={0} />
  </div>
);

// Channel picker in the audio inspector, Mic active.
export const AudioChannels = () => (
  <div style={wrap}>
    <SLSegmented options={['Mixed', 'Mic', 'System']} selected={1} />
  </div>
);
