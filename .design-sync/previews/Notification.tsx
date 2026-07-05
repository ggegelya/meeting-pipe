import { Notification } from 'meeting-pipe-design';

export const Done = () => <Notification kind="done" />;

export const Started = () => <Notification kind="started" body="20260705-1030.wav" />;

export const Processing = () => <Notification kind="processing" body="Processing 20260705-1030.wav…" />;

export const ErrorState = () => <Notification kind="error" body="Notion publish failed (401)" />;

export const CustomCopy = () => (
  <Notification kind="done" title="Weekly sync published" body="Summary and 6 action items in Notion" action="Open page" />
);
