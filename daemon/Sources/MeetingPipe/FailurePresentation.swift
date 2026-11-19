import Foundation

struct FailureMetadata: Codable, Equatable, Hashable {
    enum Cause: String, Codable {
        case credits, quota, connection, timeout, memory, publish, interrupted, cancelled, unknown
        case missingKey = "missing_key", rejectedKey = "rejected_key", expiredKey = "expired_key"
        case rateLimit = "rate_limit", serviceUnavailable = "service_unavailable", modelMissing = "model_missing"
        case syncedTarget = "synced_target"
        case overlayUnreadable = "overlay_unreadable"
        case modelRejected = "model_rejected"
        /// UX94: config.toml does not parse, or the pipeline's load refused a value in it.
        case config

        /// Causes whose fix is in Preferences > Pipeline rather than Integrations. One place, so
        /// the Ask, Digest and Library settings buttons cannot disagree about a new cause (PIPE28).
        var opensModelSettings: Bool { self == .memory || self == .modelMissing || self == .modelRejected }
    }
    enum Operation: String, Codable {
        case summary, ask, digest, publish, transcribe, processing, storage, integrations, model
        case renameVoice = "rename_voice"
        /// UX93: Swift-only. They label notifications and are never written to a `<stem>.error.json`,
        /// so `failure_details.OPERATIONS` and the sidecar contract do not carry them, and `decode`
        /// refuses them.
        case recording, people

        /// Never in a sidecar (UX93).
        var isNotificationOnly: Bool { self == .recording || self == .people }

        /// Whether a surface showing this failure offers a retry. Nothing stem-less in these is
        /// retryable as a job, so their explanation is the message, never "Retry when you are ready".
        var offersRetry: Bool { !(self == .recording || self == .people || self == .storage) }

        var failureTitle: String {
            switch self {
            case .summary: return "Couldn't create the summary"
            case .ask: return "Couldn't answer the question"
            case .digest: return "Couldn't create the digest"
            case .publish: return "Couldn't publish the summary"
            case .transcribe: return "Couldn't transcribe the recording"
            case .renameVoice: return "Couldn't rename this voice"
            case .storage: return "Couldn't finish the file operation"
            case .integrations: return "Couldn't connect the integration"
            case .model: return "Couldn't prepare the model"
            case .processing: return "Processing could not finish"
            case .recording: return "Couldn't record the meeting"
            case .people: return "Couldn't save the name"
            }
        }
    }
    var schemaVersion = 1
    var cause: Cause
    var operation: Operation
    var provider: String? = nil
    var httpStatus: Int? = nil
    var requestID: String? = nil
    var remedy: String? = nil

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", cause, operation, provider, remedy
        case httpStatus = "http_status", requestID = "request_id"
    }

    static let providers: Set<String> = ["anthropic", "openai", "notion", "local", "filesystem", "obsidian", "lan", "claude_cli"]

    static func decode(_ data: Data) -> FailureMetadata? {
        guard data.count < 4096, var value = try? JSONDecoder().decode(Self.self, from: data),
              value.schemaVersion == 1, !value.operation.isNotificationOnly else { return nil }
        if let provider = value.provider, !providers.contains(provider) { value.provider = nil }
        if let status = value.httpStatus, !(100...599).contains(status) { value.httpStatus = nil }
        value.requestID = safeRequestID(value.requestID)
        if let remedy = value.remedy, !["billing", "integrations", "model", "retry", "config"].contains(remedy) { value.remedy = nil }
        return value
    }

    static func safeRequestID(_ value: String?) -> String? {
        guard let value, value.range(of: "^(req_[A-Za-z0-9]{8,96}|[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12})$", options: .regularExpression) != nil else { return nil }
        return value
    }

    static func from(_ error: Error) -> FailureMetadata? {
        if case PipelineLauncher.LaunchError.reportedFailure(_, let metadata, _) = error { return metadata }
        return nil
    }
}

struct FailurePresentation: Equatable {
    let title: String
    let explanation: String
    let diagnostics: String
    let metadata: FailureMetadata
    let timestamp: String
    let isSearchModelMissing: Bool

    init(error: Error, operation: FailureMetadata.Operation = .processing, title: String? = nil) {
        // ASR12: a re-transcribe whose finalize failed after the rewrite wraps the real error to
        // carry its edit counts; the diagnostics and cause come from the error underneath, so a
        // caller that only presents the failure (Restore, Merge) loses nothing.
        let error = (error as? MeetingLibraryService.RetranscribeFailedAfterRewrite)?.underlying ?? error
        self.init(diagnostics: PipelineLauncher.diagnostics(for: error), operation: operation,
                  metadata: FailureMetadata.from(error), title: title)
    }

    init(diagnostics: String, operation: FailureMetadata.Operation = .processing,
         metadata: FailureMetadata? = nil, timestamp: String? = nil, title: String? = nil,
         savedRecording: Bool = false, savedTranscript: Bool = false, savedSummary: Bool = false) {
        let facts = metadata ?? Self.legacy(diagnostics, operation: operation)
        self.metadata = facts
        self.diagnostics = diagnostics
        self.timestamp = timestamp ?? ISO8601.format(Date())
        let searchModelMissing = facts.cause == .modelMissing && diagnostics.contains("Embedding model ")
            && diagnostics.contains("is not in the local HuggingFace cache")
        self.isSearchModelMissing = searchModelMissing
        let provider = SummarizationEngine.resolve(facts.provider)?.name
            ?? facts.provider.flatMap { PublishSink(rawValue: $0)?.displayName }
        let account = provider.map { "your \($0) account" } ?? "your provider account"
        var heading = facts.operation.failureTitle
        var explanation: String
        switch facts.cause {
        case .credits, .quota:
            heading = facts.cause == .credits ? "Insufficient \(provider ?? "provider") credits" : "\(provider ?? "Provider") quota reached"
            explanation = facts.cause == .credits ? "Add credits to \(account), then retry." : "Review the billing or limits on \(account), then retry."
        case .missingKey:
            heading = "\(provider ?? "Integration") key missing"
            explanation = "Add the key in Preferences > Integrations, then retry."
        case .rejectedKey:
            heading = "\(provider ?? "Integration") key not accepted"
            explanation = "Check the key in Preferences > Integrations, then retry."
        case .expiredKey:
            heading = "\(provider ?? "Integration") key expired"
            explanation = "Replace the expired key in Preferences > Integrations, then retry."
        case .connection:
            heading = "Couldn't connect\(provider.map { " to \($0)" } ?? "")"
            explanation = "Check your connection, then retry."
        case .timeout:
            heading = "The request timed out"
            explanation = "The operation did not finish in time. Retry when you are ready."
        case .rateLimit:
            heading = "Temporary request limit"
            explanation = "The service is limiting requests. Wait a moment, then retry."
        case .serviceUnavailable:
            heading = "\(provider ?? "The service") is unavailable"
            explanation = "Retry when the service is available again."
        case .interrupted:
            heading = "Processing interrupted"
            explanation = "MeetingPipe restarted before processing finished. Retry to resume."
        case .cancelled:
            heading = "Processing cancelled"
            explanation = "You cancelled this run. Retry when you are ready."
        case .modelMissing:
            heading = searchModelMissing ? "The search model is missing" : "The local model is missing"
            explanation = searchModelMissing
                ? "Download the search model, then retry Ask. Open Details for the download command for this model."
                : "Download the model, then retry. You can choose another model in Preferences > Pipeline."
        case .modelRejected:
            // No id here on purpose: the sidecar is an allowlist and carries none, and Preferences
            // shows the configured one right beside the field to change.
            heading = "\(provider ?? "The provider") does not recognise the model"
            explanation = "The configured model was retired, mistyped or is not available to your account. Pick another model in Preferences > Pipeline, then retry."
        case .memory:
            heading = "Not enough memory"
            explanation = "Close other apps or choose a smaller model in Preferences > Pipeline, then retry."
        case .syncedTarget:
            heading = "The publish folder is synced"
            explanation = "Regulated mode or an NDA workflow keeps this meeting on your Mac, and a sync client would upload it from this folder. Choose a folder outside the synced tree in Preferences > Integrations, then retry."
        case .overlayUnreadable:
            // STOR9: summarize refused rather than drop the owner's names and corrections. The file
            // is named in the diagnostics line `mp` wrote, never in the metadata.
            heading = "This meeting's edits can't be read"
            explanation = Self.overlayRefusal(diagnostics)
                ?? "A speaker names, transcript corrections or flagged moments file for this meeting is there but can't be read, so nothing was summarized. Fix or remove it, then retry."
        case .config:
            // UX94: the line or the key comes from the pipeline's own message in the stderr tail
            // (`config.toml does not parse at line 2, column 1.`); the sidecar carries neither.
            heading = "Settings file has a syntax error"
            explanation = Self.configFix(diagnostics)
        case .publish:
            heading = provider.map { "Couldn't publish to \($0)" } ?? heading
            // PIPE54: `mp publish` refused the summary before any sink, and its `[FAIL]` line says
            // which limit and what to edit; the destination is not the problem then.
            explanation = Self.refusalSentence(diagnostics)
                ?? "Check the destination in Preferences > Integrations, then retry publishing."
        case .unknown:
            explanation = "Retry when you are ready, or open Details to inspect the failure."
            if Self.isValidation(diagnostics) { explanation = diagnostics }
            else if let refusal = Self.storageRefusal(diagnostics, operation: facts.operation) { explanation = refusal }
            // UX93: no retry is offered for these, so the message itself is the explanation.
            else if !facts.operation.offersRetry, Self.isOneLine(diagnostics) { explanation = diagnostics }
        }
        var saved: [String] = []
        if savedRecording && savedTranscript { saved.append("Your recording and transcript are saved.") }
        else if savedRecording { saved.append("Your recording is saved.") }
        else if savedTranscript { saved.append("Your transcript is saved.") }
        if savedSummary { saved.append("Your saved summary is still available.") }
        self.title = title ?? heading
        let operationLine = facts.cause == .credits || facts.cause == .quota ? [facts.operation == .summary ? "The summary could not be created." : facts.operation.failureTitle + "."] : []
        self.explanation = (operationLine + saved + [explanation]).joined(separator: " ")
    }

    /// A message short and plain enough to stand as an explanation: one line, no traceback.
    static func isOneLine(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 300 && !text.contains(where: \.isNewline)
    }

    /// UX93: the operation a failure stage names, one mapping for the Library row's notice and the
    /// job-failure banner, so the two agree by construction.
    static func operation(forStage stage: String?) -> FailureMetadata.Operation {
        switch stage {
        case "publish": return .publish
        case "transcribe": return .transcribe
        default: return .summary
        }
    }

    /// UX94: what to fix in config.toml, from `mp.config.ConfigUnreadableError`'s message.
    static func configFix(_ diagnostics: String) -> String {
        if let match = diagnostics.range(of: #"does not parse at line (\d+)"#, options: .regularExpression) {
            let digits = diagnostics[match].split(separator: " ").last.map(String.init) ?? ""
            if let line = Int(digits) { return "Fix line \(line) of config.toml, then retry." }
        }
        if let match = diagnostics.range(of: #"has an invalid `[A-Za-z0-9_.]+` setting"#, options: .regularExpression) {
            let key = diagnostics[match].split(separator: "`").dropFirst().first.map(String.init) ?? ""
            if !key.isEmpty { return "Check the \(key) setting in config.toml, then retry." }
        }
        return "Fix config.toml, then retry."
    }

    /// The sentence `summarize.refuse_unreadable_overlays` writes, picked out of the stderr tail.
    static func overlayRefusal(_ diagnostics: String) -> String? {
        diagnostics.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .first { $0.contains("file can't be read") }
            .map { line in
                guard let start = line.range(of: "This meeting's") else { return line }
                return String(line[start.lowerBound...])
            }
    }

    var billingURL: URL? {
        guard [.credits, .quota].contains(metadata.cause) else { return nil }
        switch metadata.provider {
        case "anthropic": return URL(string: "https://platform.claude.com/settings/billing")
        case "openai": return URL(string: "https://platform.openai.com/account/billing/overview")
        default: return nil
        }
    }

    var settingsLabel: String? {
        if isSearchModelMissing { return nil }
        switch metadata.cause {
        case .missingKey, .rejectedKey, .expiredKey, .publish, .syncedTarget: return "Open Integrations"
        case .modelMissing, .memory, .modelRejected: return "Model settings"
        case .config: return "Open Preferences"
        default: return nil
        }
    }

    func report(appVersion: String) -> String {
        let version = appVersion.range(of: "^[0-9]+(\\.[0-9]+){0,3}$", options: .regularExpression) != nil ? appVersion : "unavailable"
        let date = timestamp.range(of: "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d+)?(Z|[+-]\\d{2}:\\d{2})$", options: .regularExpression) != nil ? timestamp : "unavailable"
        var lines = ["MeetingPipe failure report", "App version: \(version)", "Timestamp: \(date)",
                     "Operation: \(metadata.operation.rawValue)", "Cause: \(metadata.cause.rawValue)"]
        if let provider = metadata.provider, FailureMetadata.providers.contains(provider) { lines.append("Provider: \(provider)") }
        if let status = metadata.httpStatus, (100...599).contains(status) { lines.append("HTTP status: \(status)") }
        if let request = FailureMetadata.safeRequestID(metadata.requestID) { lines.append("Request ID: \(request)") }
        return lines.joined(separator: "\n")
    }

    static func legacy(_ diagnostics: String, operation: FailureMetadata.Operation) -> FailureMetadata {
        let text = diagnostics.lowercased()
        var cause: FailureMetadata.Cause = .unknown
        var provider: String?
        if text.contains("anthropic") && text.contains("your credit balance is too low to access the anthropic api") {
            cause = .credits; provider = "anthropic"
        } else if text.contains("you cancelled this run") || text == "cancelled" {
            cause = .cancelled
        } else if text.contains("meetingpipe restarted before this meeting finished processing") {
            cause = .interrupted
        } else if text.contains("not in the local huggingface cache") {
            cause = .modelMissing; provider = "local"
        } else if text.contains("not enough memory") {
            cause = .memory; provider = "local"
        } else if text.contains("$anthropic_api_key is not set") {
            cause = .missingKey; provider = "anthropic"
        } else if text.contains("$openai_api_key is not set") {
            cause = .missingKey; provider = "openai"
        } else if text.contains("$notion_token is not set") {
            cause = .missingKey; provider = "notion"
        } else if text.contains("anthropic.authenticationerror") {
            cause = text.contains("key has expired") ? .expiredKey : .rejectedKey; provider = "anthropic"
        } else if text.contains("anthropic.apitimeouterror") || text.hasPrefix("pipeline timed out") {
            cause = .timeout
        } else if text.contains("anthropic.apiconnectionerror") {
            cause = .connection; provider = "anthropic"
        } else if operation == .publish { cause = .publish }
        return FailureMetadata(cause: cause, operation: operation, provider: provider)
    }

    /// STOR14: `mp backup` and `mp restore` refuse with one `[FAIL] <sentence>` line on
    /// stderr that names the fix ("... is not mounted. Plug the drive in, or pick another
    /// destination."). For a storage operation that sentence is the explanation, not
    /// something behind Details; a traceback or anything else stays there. The last such
    /// line wins, capped, and anything that looks like a secret or a payload is refused.
    static func storageRefusal(_ diagnostics: String, operation: FailureMetadata.Operation) -> String? {
        guard operation == .storage else { return nil }
        return refusalSentence(diagnostics)
    }

    /// The last `[FAIL] <sentence>` line in a stderr tail (STOR14's shape, which PIPE54's pre-sink
    /// publish refusal shares), capped, refusing anything that looks like a secret or a payload.
    static func refusalSentence(_ diagnostics: String) -> String? {
        let marker = "[FAIL] "
        guard let line = diagnostics.split(whereSeparator: \.isNewline).last(where: { $0.contains(marker) }),
              let start = line.range(of: marker)?.upperBound else { return nil }
        let sentence = line[start...].trimmingCharacters(in: .whitespaces)
        guard !sentence.isEmpty, sentence.count <= 400, !sentence.contains("sk-"), !sentence.contains("{") else { return nil }
        return sentence
    }

    private static func isValidation(_ text: String) -> Bool {
        guard text.count <= 260, !text.contains("\n"), !text.contains("/"), !text.contains("{"), !text.contains("sk-") else { return false }
        return ["Enter a ", "Choose a ", "Type a ", "Paste a ", "The name ", "A voice named ", "The default workflow ", "No transcript ", "No summary ", "No audio ", "No recording ", "Transcription is not available", "Speech models are not downloaded", "A stretch marked off the record", "Transcription did not finish", "Apple Intelligence did not answer", "This meeting's workflow settings could not be saved", "Regulated mode is on:", "Set NOTION_TOKEN in Preferences", "Database id is not a valid value.", "Database not found, or the integration is not connected", "The summary has ", "The title is ", "Could not save "].contains { text.hasPrefix($0) }
    }
}
