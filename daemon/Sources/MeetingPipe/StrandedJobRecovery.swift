import Foundation

/// Detects pipeline jobs stranded by a mid-processing daemon restart (crash,
/// kill, rebuild): a finished recording (`<stem>.wav` merged) whose pipeline
/// never reached a terminal outcome on disk, because the in-memory
/// `SinkDispatcher` queue did not survive the restart. Without recovery these
/// masquerade as `.processing` for the staleness window, then decay to a generic
/// `.failed` (PIPE3 / AUD-16b).
///
/// Distinct from `OrphanRecordingRecovery`, which handles the other half: stems
/// with unmerged `.mic.wav`/`.system.wav` intermediates and NO final `.wav`. The
/// two sets are disjoint by construction (orphan = no final wav; stranded = has a
/// final wav), so a stem is recovered by exactly one of them.
enum StrandedJobRecovery {

    /// A `<stem>.wav` (excluding the `.mic.wav`/`.system.wav` capture
    /// intermediates, which also carry the `.wav` extension).
    private static func isFinalWav(_ name: String) -> Bool {
        name.hasSuffix(".wav")
            && !name.hasSuffix(".mic.wav")
            && !name.hasSuffix(".system.wav")
    }

    /// The terminal pipeline sidecars: any one of these means the pipeline
    /// reached an outcome (done / failed / paste-ready / empty-skip) and the stem
    /// is NOT stranded.
    private static func isTerminalSidecar(_ name: String) -> Bool {
        name.hasSuffix(".summary.json")
            || name.hasSuffix(PipelineFailureSidecar.suffix)   // .error.json
            || name.hasSuffix(".READY_FOR_MANUAL.md")
            || name.hasSuffix(EmptyMarker.suffix)              // .empty.json
    }

    /// Stems with a final `.wav` and no terminal sidecar. Pure and filename-only
    /// so it is unit-testable and cheap to run once at startup. Caller-side, only
    /// stems that parse as real recordings (`MeetingStore.parseStem`) should be
    /// acted on.
    static func detect(fileNames: [String]) -> [String] {
        var finalWavStems: Set<String> = []
        var terminalStems: Set<String> = []
        for name in fileNames {
            guard let dot = name.firstIndex(of: ".") else { continue }
            let stem = String(name[..<dot])
            if stem.isEmpty { continue }
            if isFinalWav(name) { finalWavStems.insert(stem) }
            if isTerminalSidecar(name) { terminalStems.insert(stem) }
        }
        return finalWavStems.subtracting(terminalStems).sorted()
    }
}
