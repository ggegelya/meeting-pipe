import { MenuItem, MenuSep } from 'meeting-pipe-design';

// A hairline between two folder items, inside the same menu column.
export const BetweenItems = () => (
  <div style={{ width: 240, background: 'var(--mp-bg-raised)', border: '1px solid var(--mp-border)', borderRadius: 8, padding: 4, fontFamily: 'var(--mp-font-sans)', fontSize: 'var(--mp-text-base)', color: 'var(--mp-fg)' }}>
    <MenuItem>Open Logs Folder</MenuItem>
    <MenuSep />
    <MenuItem>Open Recordings Folder</MenuItem>
  </div>
);
