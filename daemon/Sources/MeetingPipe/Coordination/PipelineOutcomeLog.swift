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

    /// The sinks that failed, by their `output.sinks` name, sorted.
    static func failedSinks(_ publish: PublishResult?) -> [String] {
        (publish?.sinks ?? []).filter { !$0.ok }.map(\.name).sorted()
    }

    /// The success row's publish attributes: `published`, `sinks`, and UX90's `publish_state`
    /// (`publish.json`'s state, or null when the run wrote none) and `skip_reason` (`paste` when the
    /// run left a paste bundle and no summary, else null). Never `page_url`.
    static func publishAttributes(_ publish: PublishResult?, pasteSkip: Bool = false) -> [String: Any] {
        let sinks = publishedSinks(publish)
        return [
            "published": !sinks.isEmpty, "sinks": sinks,
            "publish_state": publish?.state ?? NSNull(),
            "skip_reason": pasteSkip ? "paste" : NSNull(),
        ]
    }

    /// The daemon.log success line: the sinks that landed, or "local-only". A paste-bundle skip says
    /// so instead of "OK" (UX90), and a partial publish names the sinks that failed.
    static func successLine(_ publish: PublishResult?, pasteSkip: Bool = false) -> String {
        if pasteSkip { return "pipeline skipped (paste bundle)" }
        let sinks = publishedSinks(publish)
        let landed = sinks.isEmpty ? "local-only" : sinks.joined(separator: ",")
        if publish?.state == "partial" {
            return "pipeline OK (partial: \(failedSinks(publish).joined(separator: ","))) -> \(landed)"
        }
        return "pipeline OK -> \(landed)"
    }

    /// A fixed class for an error, never its description.
    static func errorType(_ error: Error) -> String {
        switch error {
        case PipelineLauncher.LaunchError.mpNotFound: return "mp_not_found"
        case PipelineLauncher.LaunchError.nonZeroExit: return "non_zero_exit"
        case PipelineLauncher.LaunchError.reportedFailure: return "reported_failure"
        case PipelineLauncher.LaunchError.uncaughtSignal: return "uncaught_signal"
        case PipelineLauncher.LaunchError.timeout: return "timeout"
        case PipelineLauncher.LaunchError.cancelled: return "cancelled"
        default: return String(describing: type(of: error))
        }
    }

    /// The failure row's attributes, one builder for `pipeline_failed`, `retranscribe_failed`,
    /// `regenerate_failed` and `republish_failed` (OBS3): the stage, the error's class, how the
    /// process ended (`termination_reason` `exit` with `exit_code`, or `signal` with `signal`), and
    /// the pipeline's typed `cause`, `operation` and `provider` when it reported them. All fixed
    /// vocabularies; never the error's text (SEC38).
    static func failureAttributes(_ error: Error, stage: PipelineFailureSidecar.Stage) -> [String: Any] {
        var attributes: [String: Any] = ["stage": stage.rawValue, "error_type": errorType(error)]
        if let metadata = FailureMetadata.from(error) {
            attributes["cause"] = metadata.cause.rawValue
            attributes["operation"] = metadata.operation.rawValue
            if let provider = metadata.provider { attributes["provider"] = provider }
        }
        switch error {
        case PipelineLauncher.LaunchError.nonZeroExit(let code, _),
             PipelineLauncher.LaunchError.reportedFailure(let code, _, _):
            attributes["exit_code"] = Int(code)
            attributes["termination_reason"] = "exit"
        case PipelineLauncher.LaunchError.uncaughtSignal(let signal, _):
            attributes["signal"] = Int(signal)
            attributes["termination_reason"] = "signal"
        default: break
        }
        return attributes
    }

    /// The daemon.log failure line. OBS3: the exit status or the signal again, which UX80's caption
    /// change dropped on 2026-09-14.
    static func failureLine(_ error: Error, stage: PipelineFailureSidecar.Stage) -> String {
        var line = "pipeline FAIL -> stage=\(stage.rawValue) error_type=\(errorType(error))"
        switch error {
        case PipelineLauncher.LaunchError.nonZeroExit(let code, _),
             PipelineLauncher.LaunchError.reportedFailure(let code, _, _):
            line += " exit=\(code)"
        case PipelineLauncher.LaunchError.uncaughtSignal(let signal, _):
            line += " signal=\(signal)"
        default: break
        }
        return line
    }
}
