# EGRESS1: Confirm Apple Intelligence zero-egress on the wire

Band origin: split out of VALID1 on 2026-07-16 by owner decision (the bar was waived, not measured). Status and priority live in this task's ToC row in [meetingpipe-q6-backlog.md](../meetingpipe-q6-backlog.md). This file exists to carry the owner walkthrough (added 2026-07-30); the spec substance stays in the ToC row.

The claim: an Apple Intelligence summary produces zero non-loopback network connections. It currently rests on argument (on-device Foundation Model, no outbound HTTP in the daemon, `egress_guard` clamps under NDA), never on watching the wire. P4, deferred: promote only if the claim becomes load-bearing (an NDA meeting that actually depends on it, or the claim made to someone else).

## Owner walkthrough (for the session that picks this up)

Added 2026-07-30 at the owner's request: every task gated on an owner action carries one. Steps are tagged [owner] / [session] by who acts.

1. Do not run this out of curiosity; it stays deferred until the trigger in the row fires. Running it early is harmless but spends owner time on a P4.
2. [owner] Install and arm an outbound firewall that alerts per connection (Little Snitch, or LuLu which is free), in alert-all mode for the MeetingPipe daemon and its child processes.
3. [owner] Re-summarize one NDA meeting with the Apple Intelligence engine while the firewall is armed, and note every connection alert attributed to MeetingPipe or its children during the run.
4. [session] Pass is zero non-loopback connections attempted for the whole run (loopback to the local model server is expected and fine). Record the observed result in the ToC row with the date.
5. On a pass, EGRESS1 closes measured, and the VALID1 leg it split from stops being waived. On a fail, the connection's destination is the finding: file it as its own task immediately, because it contradicts a written privacy claim.
