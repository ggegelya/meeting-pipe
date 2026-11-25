import Foundation

/// The summarization backend a run of one meeting will use, decided in one place (PIPE52).
///
/// Mirrors the pipeline's `config.effective_backend` over `workflow.apply_overrides` plus PIPE6's
/// one-shot override: regulated (the global flag or the sidecar's own `regulated_mode`) forces
/// `local`, then an NDA workflow or a sidecar that exists but cannot be read forces `local`
/// (SEC25 fails closed), then the override, then the workflow's pinned backend, then the global
/// setting. Pure: the caller supplies the sidecar read and the two global values, so
/// `PipelineLauncher.cloudSecretPolicy` (which keys to hand the spawn) and
/// `MeetingLibraryService` (which engine to dispatch) answer from the same function. Before
/// PIPE52 the Library dispatched on the global backend alone, so an Apple-pinned meeting spawned
/// an `mp summarize` that could only fail, and the on-device preview ran on whatever the
/// workflow pinned.
enum EffectiveBackend {
    struct Resolution: Equatable {
        var backend: String
        /// Which setting decided it: `regulated`, `nda`, `override`, `sidecar` or `global` (OBS5).
        var source: String
        var regulated: Bool
        var nda: Bool

        /// `backend` typed, for the predicates (ARCH14). `backend` itself stays the raw id, since
        /// it can come off a sidecar and goes into event attributes and `--backend` verbatim.
        var backendID: SummarizationBackend { SummarizationBackend(rawValue: backend) }
    }

    static func resolve(
        meta: MeetingMetaRead,
        globalRegulated: Bool,
        globalBackend: String,
        override: String?
    ) -> Resolution {
        var regulated = globalRegulated
        var nda = false
        var sidecarBackend: String?
        switch meta {
        case .absent:
            break
        case .loaded(let obj):
            nda = (obj["workflow_nda_mode"] as? Bool) ?? false
            regulated = regulated || ((obj["regulated_mode"] as? Bool) ?? false)
            sidecarBackend = obj["workflow_backend"] as? String
        case .unreadable:
            nda = true
        }
        // PIPE6: the override wins over the meeting's persisted backend but never over regulated
        // or NDA, which still force local, so it cannot widen egress.
        let local = SummarizationEngine.local.id
        if regulated { return Resolution(backend: local, source: "regulated", regulated: true, nda: nda) }
        if nda { return Resolution(backend: local, source: "nda", regulated: false, nda: true) }
        if let override { return Resolution(backend: override, source: "override", regulated: false, nda: false) }
        if let sidecarBackend { return Resolution(backend: sidecarBackend, source: "sidecar", regulated: false, nda: false) }
        return Resolution(backend: globalBackend, source: "global", regulated: false, nda: false)
    }

    /// The ids of the engines that run on this Mac (`local`, `apple_intelligence`), read off
    /// `SummarizationEngine.locality` rather than listed (ARCH14).
    static let onDevice: Set<String> = Set(SummarizationEngine.all.filter { $0.locality == .onDevice }.map(\.id))

    /// Which on-device engine the Summary tab's "Re-run locally (preview)" runs for a meeting, or
    /// nil when it is not offered (PIPE52). The meeting's own engine when that is on-device;
    /// otherwise the global setting's when that is on-device, so an owner on a local global
    /// backend can still preview a meeting whose workflow pins a cloud one, on-device. Never a
    /// cloud backend: the caller dispatches Apple to the Swift summarizer and `local` as an
    /// explicit `--backend local`, so what the workflow pins cannot move the run off this Mac.
    static func localPreviewEngine(resolved: String, global: String) -> String? {
        if onDevice.contains(resolved) { return resolved }
        if onDevice.contains(global) { return global }
        return nil
    }
}
