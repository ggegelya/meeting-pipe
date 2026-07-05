import { MeetingPrompt } from 'meeting-pipe-design';

const desk = {
  background: 'linear-gradient(180deg, #2C3037 0%, #14161A 100%)',
  padding: 24,
  borderRadius: 12,
  display: 'inline-block',
};

export const DetectedZoom = () => (
  <div style={desk}>
    <MeetingPrompt />
  </div>
);

export const DetectedTeams = () => (
  <div style={desk}>
    <MeetingPrompt
      source={{ displayName: 'Microsoft Teams' }}
      workflow={{ name: '1:1s', color: 'var(--mp-warning-600)' }}
    />
  </div>
);

export const NoWorkflowChip = () => (
  <div style={desk}>
    <MeetingPrompt workflow={null} />
  </div>
);
