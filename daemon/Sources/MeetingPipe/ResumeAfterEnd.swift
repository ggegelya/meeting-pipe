import Foundation

/// END17 item 5: the way back from an end that turns out to be wrong.
///
/// Every end END17 still accepts can be wrong in one shape or another: a dwell that ran out while a
/// presenter stayed on another tab, an app quit that was really a relaunch. Before this, the next
/// minute was the worst place to be wrong, because the reprompt cooldown (`reprompt_cooldown_sec`)
/// suppressed the prompt for the same app, and a prompt that did appear timed out to Skip after
/// 30 s. A user who did not notice within about 90 s lost the rest of the meeting; one who did got
/// two recordings that only a manual merge joined (PD-9).
///
/// So the end leaves this behind for a short window. If the same app's call is sighted again
/// inside it, the cooldown is bypassed and recording resumes without a prompt, under the same
/// workflow and summary mode, into a new stem that names this one (`resumed_from`), and the Library
/// offers FEAT9's merge for the pair. A genuine back-to-back call in the same app inside the window
/// is recorded too, which the cooldown used to suppress silently; it carries a merge offer the owner
/// can ignore, which is the cheap direction to be wrong in.
struct ResumeAfterEnd: Equatable {
    let bundleID: String
    /// The stem of the recording the end stopped.
    let stem: String
    let endedAt: Date
    let workflowID: UUID?
    let summaryMode: SummaryMode

    /// The spec's proposed window: a minute past the 60 s cooldown, so a call that is still up is
    /// re-sighted several times inside it even at discovery's quiet 12 s cadence, and short enough
    /// that a different meeting joined minutes later still gets its own prompt.
    static let windowSec: TimeInterval = 120

    /// The `<stem>.meta.json` key naming the earlier recording.
    static let metaKey = "resumed_from"

    func applies(to bundleID: String, at now: Date) -> Bool {
        let sinceEnd = now.timeIntervalSince(endedAt)
        return bundleID == self.bundleID && sinceEnd >= 0 && sinceEnd <= Self.windowSec
    }
}
