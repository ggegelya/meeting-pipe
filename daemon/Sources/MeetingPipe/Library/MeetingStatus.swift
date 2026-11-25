import Foundation

/// ARCH20: the one status ladder. `MeetingStore.buildMeeting` (the Library), the menu's failed-row
/// count (`MeetingStore.unrecoveredFailureStems`), `LibraryMover.inFlightReason` and
/// `AudioRetentionSweep.candidates` each collect the facts they can see and ask `decide`, so a
/// meeting cannot be failed in the Library and settled for the retention sweep (F060), or
/// terminal for one reader and in flight for another.
///
/// Which failure counts is `MeetingStore.errorIsCurrent` (UX90); this type orders it against the
/// summary, the paste bundle, the empty marker and the age window, and says whether the row may be
/// cached and whether there is a row at all. Pure: no URLs, no disk, `now` injected.
enum MeetingStatus {

    /// The stem's recording, as far as the status reads it.
    enum Audio: Equatable, Sendable {
        case none
        /// `<stem>.wav` or `<stem>.flac`.
        case finalRecording
        /// A fresh `.mic.wav` / `.system.wav`: a live capture. It exists only while the file is
        /// fresh, a second wall clock, so a row built on it is never cacheable (TECH-A17).
        case captureIntermediate
    }

    /// `<stem>.error.json`, as far as the reader opened it.
    enum ErrorSidecar: Equatable, Sendable {
        /// Opened and decoded: `errorIsCurrent` reads its stage, structure and mtime.
        case evidence(MeetingStore.ErrorEvidence)
        /// Present but not opened. The filename-first readers (the menu count's filename pass, the
        /// launch auto-retry, `LibraryMover`) pass this: with no summary it is current whatever it
        /// says, and beside a summary it is not, since only its content could make it so.
        case unopened
        /// Opened and did not decode: no failure, but still a terminal file, so the stem keeps a
        /// row (the Library's reading).
        case undecodable
    }

    struct Facts: Equatable, Sendable {
        var audio: Audio = .none
        var hasSummary = false
        /// The summary's mtime, which `errorIsCurrent` compares a structured failure against.
        /// Nil beside a summary means it could not be read, and `errorIsCurrent` then keeps the
        /// failure.
        var summaryModified: Date?
        var hasPasteReady = false
        var hasEmptyMarker = false
        var error: ErrorSidecar?
        /// The age clock for a stem with no terminal sidecar. The Library and the menu count pass
        /// the stem's start; `LibraryMover` passes the stem's newest write, since a long meeting
        /// that has just stopped is mid-pipeline although it started outside the window (STOR16).
        /// Nil when the stem does not parse: the age cannot be known, so it never ages into
        /// `.failed`.
        var startedAt: Date?
        /// The recorder still owns the stem (UX101): its age says nothing about a stall.
        var owned = false
    }

    struct Verdict: Equatable, Sendable {
        var status: Meeting.Status
        /// Whether no wall clock can move this verdict, so a scan may reuse the row until a file
        /// in the stem changes.
        var cacheable: Bool
        /// Whether the recorded failure is the meeting's current one, so the row carries its reason.
        var keepsFailure: Bool
    }

    /// Nil when the stem is no meeting: neither audio nor a terminal sidecar (TECH-A17). A terminal
    /// row whose audio a `drop` retention policy reclaimed still has a row.
    static func decide(_ f: Facts, now: Date) -> Verdict? {
        let hasTerminalSidecar = f.hasSummary || f.error != nil || f.hasPasteReady || f.hasEmptyMarker
        guard f.audio != .none || hasTerminalSidecar else { return nil }

        let keepsFailure: Bool
        switch f.error {
        case .evidence(let e)?:
            keepsFailure = !f.hasSummary || MeetingStore.errorIsCurrent(e, summaryModified: f.summaryModified)
        case .unopened?:
            keepsFailure = !f.hasSummary
        case .undecodable?, nil:
            keepsFailure = false
        }

        if keepsFailure { return Verdict(status: .failed, cacheable: true, keepsFailure: true) }
        if f.hasSummary { return Verdict(status: .done, cacheable: true, keepsFailure: false) }
        if f.hasPasteReady { return Verdict(status: .manualPasteReady, cacheable: true, keepsFailure: false) }
        // Pipeline finished but found no speech to summarize: terminal and cacheable, not an
        // in-flight `.processing` that would age into a misleading `.failed`.
        if f.hasEmptyMarker { return Verdict(status: .empty, cacheable: true, keepsFailure: false) }

        // No summary, no failure: in flight, never started, or stalled. Age is the proxy.
        if f.owned {
            // UX101: not cacheable, so the first scan after the release decides it on age.
            return Verdict(status: .processing, cacheable: false, keepsFailure: false)
        }
        if let startedAt = f.startedAt, now.timeIntervalSince(startedAt) > Meeting.staleProcessingThresholdSec {
            // PERF22: past the window age can no longer move the status, so only a file change
            // (which changes the signature) can, and the row is cacheable. Not on a capture
            // intermediate, which would pin a phantom row once the capture went stale.
            return Verdict(status: .failed, cacheable: f.audio == .finalRecording, keepsFailure: false)
        }
        // Age-derived: re-evaluated every scan to catch the staleness transition.
        return Verdict(status: .processing, cacheable: false, keepsFailure: false)
    }
}

extension MeetingStatus.ErrorSidecar {
    /// What `PipelineFailureSidecar.read` made of the file, with its mtime for `errorIsCurrent`.
    init(_ failure: PipelineFailureSidecar.Failure?, modified: Date) {
        guard let failure else { self = .undecodable; return }
        self = .evidence(MeetingStore.ErrorEvidence(
            stage: failure.stage, structured: failure.metadata != nil, modified: modified
        ))
    }
}
