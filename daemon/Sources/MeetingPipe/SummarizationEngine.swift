import Foundation

/// The one home for how a summarization backend is named on screen (UX31).
///
/// Keyed off the raw backend id, a `String` rather than `WorkflowBackend`,
/// because the surfaces that report what actually ran read theirs off disk:
/// `<stem>.run.json`'s `backend`, the `workflow_backend` sidecar key, and
/// `summarization.backend` in `config.toml` all carry strings, and the enum
/// models a pin rather than a result.
///
/// Before this, seven independent switch tables each restated the vocabulary.
/// `anthropic` was "Claude (cloud)" in the detail header and "Anthropic (cloud)"
/// in the `...` menu one click away, on screen together, for the same call on the
/// same meeting. Worse, the two backends nobody remembered to add on the way in
/// (`claude_cli`, `openai`) were unnamed on five of seven surfaces: a meeting
/// summarized by OpenAI showed no engine at all, and Ask printed the raw config
/// id. That is the same failure mode `ConfigDefaults` (ARCH5) exists to prevent
/// for config defaults, so the fix has the same shape: one table, every site
/// reads it, no site keeps a literal.
///
/// Adding a backend means adding one entry here. `SummarizationEngineTests`
/// fences that it is named in every register and that this list and
/// `WorkflowBackend` stay in lockstep, so a seventh backend cannot ship
/// half-named the way these two did.
struct SummarizationEngine: Equatable {

    /// Where the summarization actually happens. Drives both the parenthetical
    /// qualifier and the present-tense phrase, so a backend cannot be described
    /// as cloud in one register and on-device in another.
    enum Locality: Equatable {
        case cloud
        case onDevice
        /// `auto` only: tries the cloud, drops to on-device per run.
        case cloudThenLocal
    }

    /// The `summarization.backend` config value, the `workflow_backend` sidecar
    /// value, and `run.json`'s `backend`. A written contract with the pipeline,
    /// and never rendered.
    let id: String

    /// The bare name. Owner decision, 2026-07-28: name the vendor for the API
    /// backends, name the tool for the CLI one.
    let name: String

    let locality: Locality

    // MARK: - The vocabulary

    static let anthropic = SummarizationEngine(id: "anthropic", name: "Anthropic", locality: .cloud)

    static let openai = SummarizationEngine(id: "openai", name: "OpenAI", locality: .cloud)

    /// The one deliberate exception to the vendor rule: this names the binary it
    /// shells and the subscription it rides, not an API path.
    static let claudeCLI = SummarizationEngine(id: "claude_cli", name: "Claude CLI", locality: .cloud)

    static let appleIntelligence = SummarizationEngine(
        id: "apple_intelligence", name: "Apple Intelligence", locality: .onDevice
    )

    static let local = SummarizationEngine(id: "local", name: "Local MLX", locality: .onDevice)

    static let auto = SummarizationEngine(id: "auto", name: "Auto", locality: .cloudThenLocal)

    /// Every engine the product ships, in the order the backend pickers offer them.
    static let all: [SummarizationEngine] = [
        .anthropic, .local, .auto, .appleIntelligence, .claudeCLI, .openai,
    ]

    /// The engine behind a raw id, or nil for one this build does not know.
    ///
    /// Nil is meaningful rather than a gap: the provenance row hides itself
    /// instead of inventing a name, which is what its old `default: nil` was for.
    /// `mp summarize` writes `"unknown"` when it cannot attribute a run, and a
    /// meeting predating provenance has no `backend` at all; both land here.
    static func resolve(_ id: String?) -> SummarizationEngine? {
        guard let id = id else { return nil }
        return all.first { $0.id == id }
    }

    // MARK: - Registers

    /// The parenthetical qualifier: where this engine runs.
    var whereItRuns: String {
        switch locality {
        case .cloud:          return "cloud"
        case .onDevice:       return "on-device"
        case .cloudThenLocal: return "cloud, fall back to local"
        }
    }

    /// "Name (where it runs)". The provenance line, the Re-summarize menu, and
    /// the workflow inspector's Backend row. These are the surfaces where the
    /// question behind the label is "did this leave my Mac?", so the qualifier
    /// is not decoration.
    var qualified: String { "\(name) (\(whereItRuns))" }

    /// What a backend picker shows: the bare name, since a picker row is an
    /// identity and the group it sits in already says these are backends.
    ///
    /// `auto` is the exception, and keeps its longer gloss: "cloud, fall back to
    /// local" is behaviour rather than a name, and a picker is the one register
    /// with room to explain. It is why the workflow picker is 260pt wide.
    var pickerLabel: String { locality == .cloudThenLocal ? qualified : name }

    /// The tail of a present-tense sentence about a run: "Summarizing \(runPhrase)",
    /// "Answered \(runPhrase)". An on-device engine says *where* rather than
    /// *which*, because staying on the Mac is the reassurance those lines exist
    /// to give; a cloud engine has to name itself, so a silent local substitution
    /// cannot look like a cloud one.
    ///
    /// `auto` resolves before anything is reported (the pipeline records the
    /// backend that actually answered, never `"auto"`), so its phrase is a
    /// defensive value rather than one expected on screen.
    var runPhrase: String {
        locality == .onDevice ? "on-device" : "with \(name)"
    }

    /// `runPhrase`, but always naming the engine (UX64).
    ///
    /// The plain one deliberately says *where* rather than *which* for an
    /// on-device engine, because staying on the Mac is the reassurance that line
    /// exists to give. A substitution inverts that: the whole point is that a
    /// different engine ran than the one asked for, and someone who picked Apple
    /// Intelligence precisely to avoid a resident multi-GB model needs to be told
    /// which model they got.
    var namedRunPhrase: String {
        locality == .onDevice ? "on-device by \(name)" : "with \(name)"
    }

    // MARK: - Two engines

    /// The Ask pane's provenance footer, over the engine that ran and, when the
    /// pipeline substituted, the one that was asked for (UX64).
    ///
    /// `mp ask` and `mp digest` have no Apple Intelligence path at all: when the
    /// configured backend is `apple_intelligence`, `engine.complete_text` answers
    /// on the local MLX model instead, spawning a multi-GB process per ask and
    /// tearing it down after. PIPE12 made that fact explicit end to end on the
    /// Python side (`substituted_from` on the result, threaded into the answer
    /// JSON, plus an `engine_backend_substituted` event so a failed answer still
    /// records it) and the Swift side read none of it, so the pane said the local
    /// model answered and nothing about *why*. A log line is not a surface for a
    /// non-technical owner; this footer is.
    ///
    /// A function on this type rather than a fourth `var`, because the phrase
    /// needs **two** engines, and here rather than at the render site because
    /// UX31 exists precisely for having let seven switch tables drift.
    ///
    /// Nil when either engine is one this build cannot name, which is stricter
    /// than it looks and deliberate: falling back to the plain single-engine line
    /// on an unnameable `substitutedFrom` would render "Answered on-device" over
    /// a run the pipeline recorded as a substitution, hiding exactly the fact
    /// this exists to show. A line the reader has to decode is worse than no
    /// line, and a line that contradicts the record is worse than both.
    ///
    /// - Parameters:
    ///   - ran: `<answer>.backend`, the engine that actually answered.
    ///   - substitutedFrom: the engine that was configured, when it could not
    ///     serve. Nil on the normal path, which is present-and-null in the JSON
    ///     rather than absent, so a reader can tell "no substitution" from a
    ///     build that predates the key.
    static func answeredFooter(ran: String?, substitutedFrom: String?) -> String? {
        guard let ranEngine = resolve(ran) else { return nil }
        guard let requestedID = substitutedFrom else {
            return "Answered \(ranEngine.runPhrase)"
        }
        guard let requested = resolve(requestedID) else { return nil }
        // "question-and-answer path" rather than a generic "cannot run here":
        // the reason is specific and checkable, and it tells the owner their
        // choice is still honoured everywhere else (summaries do run on Apple
        // Intelligence), which a vaguer sentence would leave them doubting.
        return "Answered \(ranEngine.namedRunPhrase), because \(requested.name) has no question-and-answer path."
    }
}

extension WorkflowBackend {
    /// The display vocabulary for a pinned backend (UX31). Exhaustive by
    /// construction, so a new case cannot compile until it names itself, and the
    /// workflow surfaces never have to handle a nil the fence already rules out.
    var engine: SummarizationEngine {
        switch self {
        case .anthropic:         return .anthropic
        case .local:             return .local
        case .auto:              return .auto
        case .appleIntelligence: return .appleIntelligence
        case .claudeCLI:         return .claudeCLI
        case .openai:            return .openai
        }
    }
}
