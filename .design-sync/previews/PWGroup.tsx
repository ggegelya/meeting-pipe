import { PWField, PWGroup, PWRow, PWSegmented, PWTag, PWToggle } from 'meeting-pipe-design';

// A settings group the way the Preferences window composes one.
export const RecordingGroup = () => (
  <div style={{ width: 460, fontFamily: 'var(--mp-font-sans)', color: 'var(--mp-fg)' }}>
    <PWGroup label="Recording" footer="Recordings land in ~/Recordings as 48 kHz wav.">
      <PWRow label="Launch at login" sublabel="Start the menu-bar daemon when you sign in." first>
        <PWToggle on />
      </PWRow>
      <PWRow label="Auto-record detected meetings">
        <PWToggle />
      </PWRow>
      <PWRow label="File format">
        <PWSegmented options={['wav', 'flac']} selected={0} />
      </PWRow>
    </PWGroup>
  </div>
);

// Text inputs and tag chips inside a group.
export const WithFieldsAndTags = () => (
  <div style={{ width: 460, fontFamily: 'var(--mp-font-sans)', color: 'var(--mp-fg)' }}>
    <PWGroup label="Detection" footer="Meetings whose title matches a skip keyword never prompt.">
      <PWRow label="Recordings folder" first>
        <PWField value="~/Recordings" mono width={180} />
      </PWRow>
      <PWRow label="Skip keywords" alignTop>
        <span style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          <PWTag>standup</PWTag>
          <PWTag>focus block</PWTag>
        </span>
      </PWRow>
    </PWGroup>
  </div>
);

// Bare group: no label, no footer.
export const Minimal = () => (
  <div style={{ width: 460, fontFamily: 'var(--mp-font-sans)', color: 'var(--mp-fg)' }}>
    <PWGroup>
      <PWRow label="Verbose logging" sublabel="Adds MP_VERBOSE=1 detail to the event log." first>
        <PWToggle />
      </PWRow>
    </PWGroup>
  </div>
);
