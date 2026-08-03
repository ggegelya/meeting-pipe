import Foundation

/// The named positions behind Preferences ▸ Pipeline ▸ Speaker labels ▸ "Speaker
/// separation", over `transcription.diarization_clustering_threshold` (DIAR3), plus
/// the clamp both readers of that key share.
///
/// **Why three named positions and not a slider** (DIAR3's decision, recorded here
/// because the control is where someone would ask): the valid range is narrow
/// (FluidAudio's 0.5-0.9), the effect is coarse (it moves whole clusters, not a
/// percentage of anything), and the number explains nothing on its own, while
/// "More distinct / Balanced / Merge more" says exactly what is being traded. A
/// slider would invite fine-tuning a value whose only honest calibration is DIAR2's
/// owner-owed DER sweep, and would imply a precision the knob does not have.
///
/// Neither the default nor the range is this type's to change: DIAR2 owns both.
///
/// Pure, so the table below is testable without a view or a config.
enum SpeakerSeparation {

    /// One named position: what the control shows, and what it writes.
    struct Position: Equatable {
        let id: String
        let label: String
        let value: Double
    }

    /// FluidAudio's documented valid range for `clusteringThreshold`.
    static let validRange: ClosedRange<Double> = 0.5...0.9

    /// The tag the control carries when the config holds a value no position pins.
    ///
    /// It is a **readout, never a target**: `value(forID:)` returns nil for it, and
    /// `options(forValue:)` offers it only while it is already the selection. So there
    /// is no option a user can reach here that does nothing.
    ///
    /// The local-model picker (UX43) resolves the same tension the other way: its
    /// Custom is a real target, because there is a field behind it to type a model id
    /// into. A threshold has no such field, and inventing one would be the slider this
    /// control exists instead of, so Custom stays a readout here. What both refuse is
    /// the shape UX43 found and fixed: an option always on offer whose setter drops it,
    /// leaving the picker to snap back to the previous selection.
    static let customId = "__custom"

    /// Lower means more distinct speakers, higher merges more voices into one.
    /// Ordered the way the control reads, left to right.
    static let all: [Position] = [
        Position(id: "distinct", label: "More distinct", value: 0.55),
        Position(id: "balanced", label: "Balanced", value: 0.65),
        Position(id: "merge", label: "Merge more", value: 0.75),
    ]

    /// Clamp a raw config value into FluidAudio's range. Shared by `Config.load` and
    /// `ConfigStore.init` so Preferences can never show a value the daemon would not
    /// use: without it a hand-edited `0.2` reads as some position (or Custom) in the
    /// UI while the running daemon is on 0.5.
    static func clamp(_ raw: Double) -> Double {
        min(validRange.upperBound, max(validRange.lowerBound, raw))
    }

    /// The position a stored value selects, falling through to `customId` for a value
    /// no position pins. The `LocalModelPreset` idiom: a hand-edited 0.60 keeps its
    /// value and reads as Custom rather than being silently rounded to a preset.
    ///
    /// The epsilon defends against float representation only, not against rounding:
    /// 0.6 is Custom, deliberately, because 0.6 is a value the owner's DER sweep may
    /// have chosen and quietly rewriting it to 0.55 or 0.65 would undo that.
    static func id(forValue value: Double) -> String {
        all.first { abs($0.value - value) < 1e-9 }?.id ?? customId
    }

    /// The value a position writes, or nil for `customId`, which writes nothing.
    static func value(forID id: String) -> Double? {
        all.first { $0.id == id }?.value
    }

    /// The Custom position's label, carrying the value it stands for. A segmented
    /// control has no second field to reveal the number in, and "Custom" alone would
    /// hide the one thing the user needs in order to decide whether to leave it.
    static func customLabel(forValue value: Double) -> String {
        String(format: "Custom (%.2f)", value)
    }

    /// The control's options for a stored value: the three named positions, plus
    /// Custom appended only when the value is already a non-preset one.
    static func options(forValue value: Double) -> [(value: String, label: String)] {
        var out = all.map { (value: $0.id, label: $0.label) }
        if id(forValue: value) == customId {
            out.append((value: customId, label: customLabel(forValue: value)))
        }
        return out
    }
}

/// Copy for Preferences ▸ Pipeline ▸ Speaker labels ▸ "Clean up speaker labels after
/// transcription", over `summarization.diarize_cleanup` (DIAR3).
///
/// Pure and backend-keyed because the honest sentence changes with the backend, and
/// the clause that matters most is the one about regulated / NDA meetings. Saying
/// "NDA meetings run it on this Mac" under a backend that already runs everything on
/// this Mac is not a reassurance, it is noise that implies a cloud call the user
/// never configured. The pipeline's own rule is the thing being described:
/// `diarize_cleanup._select_cleanup_backend` resolves through `config.effective_backend`
/// (the TECH-ARCH1 chokepoint that forces `local` whenever `zero_egress` holds), after
/// `entry.prepare` has armed the egress guard on the per-meeting resolved config.
enum DiarizeCleanup {

    /// What the pass costs and when it runs. True on every backend.
    ///
    /// "multi-speaker" is exact rather than hedging: `cleanup_transcript` returns
    /// without an LLM call when the transcript has fewer than two distinct speakers.
    ///
    /// The apply step is deliberately not Re-transcribe. `mp finalize` (the tail of
    /// the Re-transcribe ratchet, ASR3) does not run this pass, and Re-summarize only
    /// re-runs the summary over the transcript on disk, so `run-all` on a new meeting
    /// is the only in-app path that runs it.
    static let base = """
        An extra model call per multi-speaker meeting: after transcription the model \
        merges labels that are one person and fixes obvious mis-attributions. Applies \
        to meetings recorded from now on; neither Re-transcribe… nor Re-summarize \
        runs it over a meeting you already have.
        """

    /// The full sublabel for a configured `summarization.backend` id.
    ///
    /// An id this build does not know gets `base` alone: the provenance rule from
    /// `SummarizationEngine.resolve` (say nothing rather than invent a locality),
    /// which matters more here than elsewhere because the sentence being invented
    /// would be a promise about where a transcript goes.
    static func sublabel(backendID: String) -> String {
        guard let engine = SummarizationEngine.resolve(backendID) else { return base }
        switch engine.locality {
        case .cloud, .cloudThenLocal:
            return base + " It follows your summarization backend, so a regulated or "
                + "NDA meeting runs it on this Mac instead."
        case .onDevice where engine.id == SummarizationEngine.appleIntelligence.id:
            // Apple Intelligence summarizes in the daemon; the cleanup pass runs in
            // Python, which has no Foundation Model path, so it uses the local MLX
            // model (`_select_cleanup_backend` collapses apple_intelligence to local).
            return base + " It runs on the local MLX model: Apple Intelligence "
                + "summarizes, but does not do this pass."
        case .onDevice:
            return base + " It runs on this Mac, like your summaries."
        }
    }
}
