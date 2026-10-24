import Foundation

struct FailureMetadata: Codable, Equatable, Hashable {
    enum Cause: String, Codable {
        case credits, quota, connection, timeout, memory, publish, interrupted, cancelled, unknown
        case missingKey = "missing_key", rejectedKey = "rejected_key", expiredKey = "expired_key"
        case rateLimit = "rate_limit", serviceUnavailable = "service_unavailable", modelMissing = "model_missing"
    }
    enum Operation: String, Codable {
        case summary, ask, digest, publish, transcribe, processing, storage, integrations, model
        case renameVoice = "rename_voice"

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
              value.schemaVersion == 1 else { return nil }
        if let provider = value.provider, !providers.contains(provider) { value.provider = nil }
        if let status = value.httpStatus, !(100...599).contains(status) { value.httpStatus = nil }
        value.requestID = safeRequestID(value.requestID)
        if let remedy = value.remedy, !["billing", "integrations", "model", "retry"].contains(remedy) { value.remedy = nil }
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
        self.init(diagnostics: PipelineLauncher.diagnostics(for: error), operation: operation,
                  metadata: FailureMetadata.from(error), title: title)
    }

    init(diagnostics: String, operation: FailureMetadata.Operation = .processing,
         metadata: FailureMetadata? = nil, timestamp: String? = nil, title: String? = nil,
         savedRecording: Bool = false, savedTranscript: Bool = false, savedSummary: Bool = false) {
        let facts = metadata ?? Self.legacy(diagnostics, operation: operation)
        self.metadata = facts
        self.diagnostics = diagnostics
        self.timestamp = timestamp ?? ISO8601DateFormatter().string(from: Date())
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
        case .memory:
            heading = "Not enough memory"
            explanation = "Close other apps or choose a smaller model in Preferences > Pipeline, then retry."
        case .publish:
            heading = provider.map { "Couldn't publish to \($0)" } ?? heading
            explanation = "Check the destination in Preferences > Integrations, then retry publishing."
        case .unknown:
            explanation = "Retry when you are ready, or open Details to inspect the failure."
            if Self.isValidation(diagnostics) { explanation = diagnostics }
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
        case .missingKey, .rejectedKey, .expiredKey, .publish: return "Open Integrations"
        case .modelMissing, .memory: return "Model settings"
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

    private static func isValidation(_ text: String) -> Bool {
        guard text.count <= 260, !text.contains("\n"), !text.contains("/"), !text.contains("{"), !text.contains("sk-") else { return false }
        return ["Enter a ", "Choose a ", "Type a ", "Paste a ", "The name ", "A voice named ", "The default workflow ", "No transcript ", "No summary ", "No audio ", "No recording ", "Transcription is not available", "A stretch marked off the record", "Regulated mode is on:", "Set NOTION_TOKEN in Preferences", "Database id is not a valid value.", "Database not found, or the integration is not connected"].contains { text.hasPrefix($0) }
    }
}
