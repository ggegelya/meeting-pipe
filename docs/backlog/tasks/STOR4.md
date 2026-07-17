# STOR4: Scheduled automatic backups

Band origin: assessment review 2026-07-12. Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md).

**STOR4 (P2): scheduled automatic backups.** The corpus is irreplaceable (the 2026-07-05 review's own framing) yet `mp backup` runs only when the owner clicks "Back up now" or remembers the CLI, and doctor merely reports staleness. Copy the AI4 launch-agent mechanism exactly: a Preferences Storage toggle (+ day/time and target-directory picker) that installs `~/Library/LaunchAgents/com.meetingpipe.backup.plist` running `mp backup <dir>`, `launchctl bootstrap`/`bootout` on toggle, last-run age surfaced beside the existing button. Acceptance: with the toggle on, a scheduled backup lands unattended and doctor's last-backup age stays fresh; toggling off removes the agent; the manifest lands per STOR2's contract.
