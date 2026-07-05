import { PWGroup, PWRow, PWSegmented, PWTag, PWToggle } from 'meeting-pipe-design';

// Inline rows: label grows, compact control hugs the right.
export const InlineControls = () => (
  <div style={{ width: 460, fontFamily: 'var(--mp-font-sans)', color: 'var(--mp-fg)' }}>
    <PWGroup>
      <PWRow label="Launch at login" sublabel="Start the menu-bar daemon when you sign in." first>
        <PWToggle on />
      </PWRow>
      <PWRow label="File format">
        <PWSegmented options={['wav', 'flac']} selected={0} />
      </PWRow>
    </PWGroup>
  </div>
);

// alignTop keeps the label pinned while a tall control wraps.
export const AlignTop = () => (
  <div style={{ width: 460, fontFamily: 'var(--mp-font-sans)', color: 'var(--mp-fg)' }}>
    <PWGroup>
      <PWRow label="Skip keywords" sublabel="Never prompt for these" alignTop first>
        <span style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          <PWTag>standup</PWTag>
          <PWTag>focus block</PWTag>
        </span>
      </PWRow>
    </PWGroup>
  </div>
);
