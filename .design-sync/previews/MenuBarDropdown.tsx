import { MenuBarDropdown } from 'meeting-pipe-design';

const desk = {
  background: 'linear-gradient(180deg, #2C3037 0%, #14161A 100%)',
  padding: 24,
  borderRadius: 12,
  display: 'inline-block',
};

export const Idle = () => (
  <div style={desk}>
    <MenuBarDropdown />
  </div>
);

export const Recording = () => (
  <div style={desk}>
    <MenuBarDropdown state="recording" file="20260705-1030.wav" />
  </div>
);

export const DetectedTeams = () => (
  <div style={desk}>
    <MenuBarDropdown state="prompting" source={{ displayName: 'Microsoft Teams' }} />
  </div>
);
