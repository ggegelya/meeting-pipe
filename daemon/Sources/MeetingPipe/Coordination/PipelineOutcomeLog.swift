import Foundation

/// SEC38: what a pipeline, republish or merge outcome writes to `events.jsonl` and `daemon.log`.
/// A published note's path or page address embeds the meeting title's slug, and an error's free text
/// can quote the title, so the logs carry the sink names and the error's class instead. The page link
/// stays in `<stem>.publish.json` and the full failure reason in `<stem>.error.json`; both are the
/// Library's, not logs. Pure, so a test asserts the row that ships.
enum PipelineOutcomeLog {
    /// The sinks that landed, by their `output.sinks` name, sorted (from `<stem>.publish.json`).
    static func publishedSinks(_ publish: PublishResult?) -> [String] {
        (publish?.sinks ?? []).filter(\.ok).map(\.name).sorted()
    }

    /// The success row's publish attributes: `published` and `sinks`, never `page_url`.
    static func publishAttributes(_ publish: PublishResult?) -> [String: Any] {
        let sinks = publishedSinks(publish)
        return ["published": !sinks.isEmpty, "sinks": sinks]
    }

    /// The daemon.log success line: the sinks that landed, or "local-only".
    static func successLine(_ publish: PublishResult?) -> String {
        let sinks = publishedSinks(publish)
        return "pipeline OK -> \(sinks.isEmpty ? "local-only" : sinks.joined(separator: ","))"
    }

    /// A fixed class for an error, never its description.
    static func errorType(_ error: Error) -> String {
        switch error {
        case PipelineLauncher.LaunchError.mpNotFound: return "mp_not_found"
        case PipelineLauncher.LaunchError.nonZeroExit: return "non_zero_exit"
        case PipelineLauncher.LaunchError.reportedFailure: return "reported_failure"
        case PipelineLauncher.LaunchError.timeout: return "timeout"
        case PipelineLauncher.LaunchError.cancelled: return "cancelled"
        default: return String(describing: type(of: error))
        }
    }

    /// The failure row's attributes: the stage, the error's class, and the cause and exit code when
    /// the pipeline reported them. All fixed vocabularies.
    static func failureAttributes(_ error: Error, stage: PipelineFailureSidecar.Stage) -> [String: Any] {
        var attributes: [String: Any] = ["stage": stage.rawValue, "error_type": errorType(error)]
        if let cause = FailureMetadata.from(error)?.cause { attributes["cause"] = cause.rawValue }
        switch error {
        case PipelineLauncher.LaunchError.nonZeroExit(let code, _),
             PipelineLauncher.LaunchError.reportedFailure(let code, _, _):
            attributes["exit_code"] = Int(code)
        default: break
        }
        return attributes
    }

    /// The daemon.log failure line.
    static func failureLine(_ error: Error, stage: PipelineFailureSidecar.Stage) -> String {
        "pipeline FAIL -> stage=\(stage.rawValue) error_type=\(errorType(error))"
    }
}
