import { PWSegmented } from 'meeting-pipe-design';

const wrap = { fontFamily: 'var(--mp-font-sans)', color: 'var(--mp-fg)', display: 'inline-flex' } as const;

// Two options, first selected: the recording file format picker.
export const FileFormat = () => (
  <div style={wrap}>
    <PWSegmented options={['wav', 'flac']} selected={0} />
  </div>
);

// Three options with the middle selected.
export const ThreeWay = () => (
  <div style={wrap}>
    <PWSegmented options={['Off', 'Ask', 'Always']} selected={1} />
  </div>
);
