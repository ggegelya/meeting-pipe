import { OnboardingPermissions } from 'meeting-pipe-design';

// The step-2 permission grant card, shown on the app background.
export const Default = () => (
  <div style={{ background: 'var(--mp-bg-sunk)', padding: 24, display: 'inline-block', borderRadius: 16 }}>
    <OnboardingPermissions />
  </div>
);
