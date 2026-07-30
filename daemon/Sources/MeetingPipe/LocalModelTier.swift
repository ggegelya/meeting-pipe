import Foundation

/// LOCAL16: what this Mac can actually run, as a pure policy the UI can ask before anything heavy loads.
///
/// The Preferences preset picker used to state its RAM limits as fixed prose ("~8 GB", "wants 24 GB+ RAM (can OOM on 16 GB)") with nothing reading the machine, so a 16 GB Mac and a 64 GB Mac were told the same thing and the 16 GB one found out by hanging. This is the same table `mp.resource_guard` enforces at spawn time, mirrored here because the annotation has to render before any Python runs.
///
/// **Mirror rule.** `pipeline/src/mp/resource_guard.py` owns the identical `TIERS`, `TIGHT_FRACTION`, and per-billion estimate. There is no shared constant across the language boundary, so changing one means changing the other, the same standing arrangement as the `<stem>.meta.json` sidecar and the UX21 failure marker. The tests on both sides pin the same worked rows (16 / 24 / 32 / 48 GB against 3B / 7B / 14B), so a one-sided change fails one suite.
enum LocalModelTier {

    /// One row of the policy: a machine with at least `minRamGB` may run a model estimated up to `maxModelGB`, and should keep a single request under `contextTokenCeiling`.
    struct Tier: Equatable {
        let minRamGB: Double
        let maxModelGB: Double
        let contextTokenCeiling: Int
    }

    /// Anchored on measurements, not on a ratio: the 7B (~4.3 GB) is the shipped default and is called memory-safe on 16 GB; the 14B (~8.7 GB) "wants 24 GB+ RAM (can OOM on 16 GB)" per LOCAL6; and AI2 measured the 14B on the owner's 32 GB Mac as fine at 4K tokens, watchdog-abort at 8K, OOM at 16K, which is what caps the ceilings.
    static let tiers: [Tier] = [
        Tier(minRamGB: 8, maxModelGB: 2.5, contextTokenCeiling: 2_000),
        Tier(minRamGB: 16, maxModelGB: 5.0, contextTokenCeiling: 4_000),
        Tier(minRamGB: 24, maxModelGB: 9.0, contextTokenCeiling: 4_000),
        Tier(minRamGB: 32, maxModelGB: 9.0, contextTokenCeiling: 8_000),
        Tier(minRamGB: 48, maxModelGB: 20.0, contextTokenCeiling: 16_000),
    ]

    /// Above this share of the tier's budget a model is admitted but annotated as tight. The 7B on 16 GB and the 14B on 24-32 GB both land here, which is exactly the population that has produced OOM reports.
    static let tightFraction = 0.8

    /// How a model scores against a machine. `unknown` is a model whose size does not parse (any Custom repo id): never refused on size, because guessing that a custom id is too big would break the one escape hatch the user has.
    enum Fit: Equatable {
        case fits
        case tight
        case over
        case unknown
    }

    /// The policy row for a machine with `ramGB` of physical RAM. A machine below the first tier's floor still gets that tier: there is nothing smaller to offer it.
    static func tier(forRamGB ramGB: Double) -> Tier {
        var chosen = tiers[0]
        for t in tiers where ramGB >= t.minRamGB { chosen = t }
        return chosen
    }

    /// ~0.62 GB per billion params covers 4-bit weights plus runtime overhead and matches the measured ~4.3 GB for the 7B. Nil when the repo id carries no parameter count.
    static func estimatedModelGB(_ modelId: String) -> Double? {
        guard let match = modelId.range(
            of: "[0-9]+(\\.[0-9]+)?\\s*[bB](?![a-zA-Z0-9_])", options: .regularExpression
        ) else { return nil }
        let digits = modelId[match].dropLast().trimmingCharacters(in: .whitespaces)
        guard let params = Double(digits) else { return nil }
        return (params * 0.62 * 10).rounded() / 10
    }

    static func fit(modelId: String, ramGB: Double) -> Fit {
        guard let modelGB = estimatedModelGB(modelId) else { return .unknown }
        let budget = tier(forRamGB: ramGB).maxModelGB
        if modelGB > budget { return .over }
        return modelGB > budget * tightFraction ? .tight : .fits
    }

    /// The smallest tier that would admit a model of this size, to quote back as "needs about 24 GB". Nil when no tier does.
    static func wantsRamGB(modelGB: Double) -> Double? {
        tiers.first(where: { modelGB <= $0.maxModelGB })?.minRamGB
    }

    /// The one-line annotation under a preset row. Truthful about the machine in front of the user rather than about a generic Mac, which is the whole point of reading `ProcessInfo.processInfo.physicalMemory` at all.
    static func annotation(modelId: String, ramGB: Double) -> String {
        let ram = Self.gb(ramGB)
        switch fit(modelId: modelId, ramGB: ramGB) {
        case .fits:
            return "Fits comfortably on this Mac (\(ram) GB)."
        case .tight:
            return "Runs on this Mac (\(ram) GB) with little headroom; a long meeting can push it."
        case .over:
            guard let modelGB = estimatedModelGB(modelId), let wants = wantsRamGB(modelGB: modelGB) else {
                return "Needs more memory than this Mac (\(ram) GB) has."
            }
            return "Needs about \(Self.gb(wants)) GB; this Mac has \(ram) GB."
        case .unknown:
            return "Size unknown, so it is not checked against this Mac's memory."
        }
    }

    /// A preset's row in the picker: its label plus the reason when this Mac cannot take it. The reason rides in the row text, not only in the disabled state, because a grayed menu row with no explanation is exactly the untruthful-disabled shape UX30 exists to prevent.
    static func rowLabel(_ label: String, modelId: String, ramGB: Double) -> String {
        fit(modelId: modelId, ramGB: ramGB) == .over
            ? "\(label) - \(annotation(modelId: modelId, ramGB: ramGB))"
            : label
    }

    /// True when the model is small enough for this machine to load at all. `unknown` counts as runnable: the free-RAM watchdog in the pipeline is what covers a model nobody can size.
    static func isRunnable(modelId: String, ramGB: Double) -> Bool {
        fit(modelId: modelId, ramGB: ramGB) != .over
    }

    /// This Mac's physical RAM in GB. The one read of `ProcessInfo.processInfo.physicalMemory` in the app.
    static func physicalRamGB() -> Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
    }

    /// Whole GB when it is whole, one decimal otherwise, so "16 GB" does not render as "16.0 GB".
    private static func gb(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int(value.rounded()))
            : String(format: "%.1f", value)
    }
}
