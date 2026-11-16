import Foundation

/// SEC18: the start-of-recording warning for a library a sync client owns, under a mode that
/// promised no audio at rest leaves the Mac.
///
/// Regulated mode and an NDA workflow both resolve to `CaptureMode.regulatedGate`, which zeroes muted
/// audio live. None of that matters if `~/Documents/Meetings/raw` is inside iCloud's Desktop & Documents
/// scope: every WAV and transcript uploads from the folder. The warning is never a refusal (that would
/// lose the meeting, and the audio is already gated live in this mode); it names the provider once per
/// session and offers to move the library. Pure, so the "once, and only for the regulated gate" rule is
/// testable without a notification centre or a filesystem.
struct LibrarySyncStartWarning: Equatable {

    enum Decision: Equatable {
        case warn(providerName: String)
        case none
    }

    /// Set the first time a warning is issued; a second recording in the same session stays quiet.
    private(set) var warned = false

    /// Warn for a zero-egress capture mode (`.regulatedGate`) over a synced library, once. A capture-first
    /// mode never warns: those meetings make no zero-egress promise about audio at rest.
    mutating func consider(captureMode: CaptureMode, provider: CloudSyncDetector.SyncProvider?) -> Decision {
        guard captureMode == .regulatedGate, !warned, let provider else { return .none }
        warned = true
        return .warn(providerName: provider.name)
    }

    /// Cheap pre-check the caller makes before walking the filesystem for a provider.
    func mayWarn(captureMode: CaptureMode) -> Bool {
        captureMode == .regulatedGate && !warned
    }

    static func body(providerName: String) -> String {
        "This recording is under regulated mode or an NDA workflow, but your meeting library is in a folder \(providerName) syncs, so its recordings and transcripts are uploaded. Move the library to a folder outside the synced tree."
    }
}
