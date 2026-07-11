import Foundation

/// Per-context routing rules: LLM context prompt, publish sinks, summarisation backend, and behavioural toggles (NDA mode). One TOML file per workflow under `~/.config/meeting-pipe/workflows/`; UUID is the filename so renames don't move the file. Exactly one workflow is flagged default; `WorkflowStore` enforces single-default on every save.

/// A pinnable summarisation backend. The raw values match `summarization.backend` in `config.toml` and the `workflow_backend` sidecar key, so a pin maps straight through to the pipeline. A workflow that does not pin one (`Workflow.backend == nil`) inherits the global default: the sidecar omits the key and the pipeline keeps `summarization.backend`, which is how a global Apple Intelligence setting stays reachable for normal meetings.
enum WorkflowBackend: String, Codable, Equatable, CaseIterable {
    case anthropic
    case local
    case auto
    case appleIntelligence = "apple_intelligence"
}

/// One publish destination, workflow-scoped. Empty strings fall back to the global config field.
enum WorkflowSink: Codable, Equatable, Hashable {
    case notion(databaseId: String)
    case obsidian
    case filesystem

    /// Stable string used in TOML; matches the pipeline's `output.sinks` vocabulary.
    var typeName: String {
        switch self {
        case .notion: return "notion"
        case .obsidian: return "obsidian"
        case .filesystem: return "filesystem"
        }
    }
}

/// What a workflow does with a settled meeting's audio once its retention window elapses (STOR1). Stereo WAV runs ~0.7 GB per recorded hour, so an unbounded `raw/` is the library's largest liability; a policy is how the owner trades archive fidelity for disk.
enum RetentionPolicy: String, Codable, Equatable, Hashable, CaseIterable {
    /// Never touch the audio. The default, and the only byte-preserving option.
    case keep
    /// Transcode the WAV to FLAC in place. Lossless, and stays reprocessable:
    /// both `AVAudioFile` (playback, waveform) and the pipeline's `soundfile`
    /// channel reads decode FLAC. AAC was rejected for exactly that second
    /// reason, on top of being a one-way door. Savings depend entirely on the
    /// signal: quiet speech roughly halves, a noisy room barely compresses.
    case compress
    /// Delete the audio, keeping the transcript, summary, and every sidecar. The
    /// meeting stays in the Library with its audio affordances disabled.
    case drop
}

/// Per-workflow audio retention (STOR1). Absent from a workflow's TOML means `keep` forever, so every workflow predating this stays byte-unchanged until the owner opts it in.
struct WorkflowRetention: Codable, Equatable, Hashable {
    var policy: RetentionPolicy = .keep
    /// Days after the meeting started before the policy may act. Only counted for
    /// a settled meeting; a `Needs you` row is never touched however old it is.
    var afterDays: Int = 30

    enum CodingKeys: String, CodingKey {
        case policy
        case afterDays = "after_days"
    }
}

/// Per-workflow behavioural toggles. Separate struct so future flags land without touching the Workflow shape.
struct WorkflowFlags: Codable, Equatable, Hashable {
    /// Forces `backend = .local` and `sinks = [.filesystem]` regardless of other fields. Surfaced in the HUD so a misroute is visible before recording starts.
    var ndaMode: Bool = false
    /// Opt in to offline muted-span redaction (TECH-MIC9). Off by default: a normal meeting keeps the full mic in the consumed artifact (capture-first / retention-based privacy), so a fragile mute oracle can never silently delete real speech. On, this workflow's recordings resolve to `.captureFirstRedact`: muted spans are redacted from the notes offline, the full recording is kept aside, and `MuteRedactor` withholds a runaway whole-meeting redaction over a live mic.
    var redactMutedSpans: Bool = false
}

/// One match predicate; any matching rule counts for the workflow. Empty `bundleID` matches any bundle, useful for title-regex rules targeting browser meetings that may surface as Chrome, Safari, Edge, or Arc.
struct WorkflowMatchingRule: Codable, Equatable, Hashable, Identifiable {
    var id: UUID = UUID()
    /// Exact bundle-id match. Empty matches any.
    var bundleID: String = ""
    /// Case-insensitive regex against `meetingTitle`. Empty means any title.
    var titleRegex: String = ""

    enum CodingKeys: String, CodingKey {
        case id
        case bundleID = "bundle_id"
        case titleRegex = "title_regex"
    }

    init(id: UUID = UUID(), bundleID: String = "", titleRegex: String = "") {
        self.id = id
        self.bundleID = bundleID
        self.titleRegex = titleRegex
    }
}

/// A workflow-defined extra summary section (WF7). The model fills a section named `name` following `instruction`; it flows to the pipeline via `workflow_extra_sections` in the meta sidecar, and every publisher renders it. Same id-keyed shape as `WorkflowMatchingRule` so the editor's add/remove-row pattern reuses cleanly.
struct WorkflowExtraSection: Codable, Equatable, Hashable, Identifiable {
    var id: UUID = UUID()
    /// Section title shown in the summary. A row with an empty name or instruction is dropped before it reaches the sidecar.
    var name: String = ""
    /// What the model should put in the section.
    var instruction: String = ""

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case instruction
    }

    init(id: UUID = UUID(), name: String = "", instruction: String = "") {
        self.id = id
        self.name = name
        self.instruction = instruction
    }
}

struct Workflow: Codable, Equatable, Hashable, Identifiable {
    let id: UUID
    var name: String
    /// Hex string like "#FF6B6B". Parsed by the UI on render.
    var color: String
    /// Single emoji char or nil; UI shows it instead of the color glyph.
    var emoji: String?
    var matchingRules: [WorkflowMatchingRule]
    /// Becomes `summarization.team_context` in the pipeline.
    var contextPrompt: String
    var sinks: [WorkflowSink]
    /// Pinned summarisation backend, or nil to inherit the global default.
    var backend: WorkflowBackend?
    var flags: WorkflowFlags
    /// What happens to this workflow's meeting audio once it settles (STOR1). Defaults to keep-forever.
    var retention: WorkflowRetention
    /// Workflow-defined extra summary sections (WF7). Empty for a workflow that adds none.
    var extraSections: [WorkflowExtraSection]
    /// Exactly one workflow has this set; the matcher falls back to it when no rule matches.
    var isDefault: Bool
    /// User-defined display order; ties break alphabetically by name.
    var order: Int

    init(
        id: UUID = UUID(),
        name: String,
        color: String = MPColors.defaultWorkflowHex,
        emoji: String? = nil,
        matchingRules: [WorkflowMatchingRule] = [],
        contextPrompt: String = "",
        sinks: [WorkflowSink] = [.notion(databaseId: "")],
        backend: WorkflowBackend? = nil,
        flags: WorkflowFlags = WorkflowFlags(),
        retention: WorkflowRetention = WorkflowRetention(),
        extraSections: [WorkflowExtraSection] = [],
        isDefault: Bool = false,
        order: Int = 0
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.emoji = emoji
        self.matchingRules = matchingRules
        self.contextPrompt = contextPrompt
        self.sinks = sinks
        self.backend = backend
        self.flags = flags
        self.retention = retention
        self.extraSections = extraSections
        self.isDefault = isDefault
        self.order = order
    }

    /// The extra sections worth persisting / sending: both fields non-blank. A half-filled editor row never reaches the sidecar or the model.
    var usableExtraSections: [WorkflowExtraSection] {
        extraSections.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Backend to stamp into the meta sidecar, or nil to inherit the global default (the sidecar then omits `workflow_backend`). NDA forces local regardless of the pin so the summary never leaves the Mac. Surfaced on the workflow chip so the user sees the resolution before pressing Record.
    var effectiveBackend: WorkflowBackend? {
        flags.ndaMode ? .local : backend
    }

    /// Effective sinks after NDA; NDA forces filesystem-only so the summary never leaves the Mac.
    var effectiveSinks: [WorkflowSink] {
        flags.ndaMode ? [.filesystem] : sinks
    }

    /// Sink type names for the meta sidecar's `output.sinks` override.
    var effectiveSinkTypeNames: [String] {
        effectiveSinks.map { $0.typeName }
    }

    /// Notion DB id this workflow publishes to; empty string falls back to the global `notion.database_id`.
    var notionDatabaseID: String {
        for sink in effectiveSinks {
            if case .notion(let id) = sink {
                return id
            }
        }
        return ""
    }
}
