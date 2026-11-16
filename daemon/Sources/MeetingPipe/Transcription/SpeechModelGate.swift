import Foundation

/// The two speech models `FluidAudioRunner` loads (SEC36).
enum SpeechModel: String, CaseIterable, Equatable {
    case asr
    case diarizer
}

/// SEC36: whether a job may start the in-daemon speech pass, given that FluidAudio fetches a
/// missing model from huggingface.co on its own (`AsrModels.downloadAndLoad`,
/// `DiarizerModels.downloadIfNeeded`). A zero-egress job (regulated or NDA) promised that nothing
/// leaves the Mac, model-file requests included, so it refuses a cold cache instead of fetching.
/// A normal job proceeds and downloads as it always did. The owner's rule, 2026-11-16: a
/// zero-egress meeting may not fetch speech models.
///
/// Pure on purpose: the posture and the cache state are both arguments, so the table of outcomes is
/// testable offline with no FluidAudio call. `missing` is what the runner reports, already empty
/// when it holds loaded managers (nothing will be fetched then).
enum SpeechModelGate {
    enum Decision: Equatable {
        case proceed
        case refuse(missing: [SpeechModel])
    }

    static func decide(zeroEgress: Bool, missing: [SpeechModel]) -> Decision {
        guard zeroEgress, !missing.isEmpty else { return .proceed }
        return .refuse(missing: missing)
    }

    /// The failure-sidecar reason. It opens with a prefix `FailurePresentation.isValidation`
    /// knows, so the Library row says this instead of the generic retry copy; no slash in it for
    /// the same reason.
    static let reason = "Speech models are not downloaded. Download them from a normal session first, then retry this meeting."

    /// Which models a runner still has to fetch: none while its managers are already loaded.
    /// `present` is the cache check's answer per model; both arguments are plain values so the
    /// loaded-managers rule is testable without a runner.
    static func missing(loaded: Set<SpeechModel>, present: Set<SpeechModel>) -> [SpeechModel] {
        SpeechModel.allCases.filter { !loaded.contains($0) && !present.contains($0) }
    }

    /// The error a refused job fails with. `errorDescription` is what the dispatcher writes to
    /// `<stem>.error.json`, which is what the Library row reads.
    struct Refused: LocalizedError {
        let missing: [SpeechModel]
        var errorDescription: String? { SpeechModelGate.reason }
    }
}
