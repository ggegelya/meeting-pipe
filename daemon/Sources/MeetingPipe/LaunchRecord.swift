import Foundation
import os

/// OBS5: the launch row, the id every row of this process carries, and what the previous process
/// left on its way out.
///
/// A launch with no `daemon` / `terminating` row before it was a crash or a kill, but reading that
/// off the log took a scan backwards to the previous `terminating`, and two launches could not be
/// told apart at all. `main` / `launched` says it once per process (`previous_exit`), and
/// `launch_id` on every row groups a launch's rows without timestamp arithmetic. Names only: no
/// title, no path, no device.
///
/// Both halves of the state are files written synchronously, not `UserDefaults`: the exit marker
/// is written moments before the process exits, and the launch id moments before a launch that
/// may crash, and a defaults write is handed to cfprefsd asynchronously, so either could be lost
/// in exactly the case it exists to record.
enum LaunchRecord {

    /// One id per process, stamped by `Log` on every `events.jsonl` and `diagnostics.jsonl` row.
    static let launchID = UUID().uuidString.lowercased()

    /// What a clean exit persists beside the `terminating` row, for the next launch to read.
    struct Termination: Codable, Equatable {
        /// `terminating`'s `reason` (`quit`, `sigterm`).
        let reason: String
        /// The stem of the recording open at that exit, so the next launch's orphan sweep can say
        /// the merge it makes is a shutdown's, not a crash's.
        let recordingStem: String?
        /// The launch that wrote it; a marker from any other launch is not the previous exit.
        let launchID: String
        /// UX82 item 1: the exit asked the agent for a relaunch (`AppDelegate.relaunchExitStatus`).
        /// Optional so a marker written before UX82 still decodes.
        var relaunch: Bool? = nil
    }

    /// What this launch learned about the previous one, settled once by `begin`.
    struct Previous: Equatable {
        let termination: Termination?
        let exit: String
    }

    static let terminationFileName = "last-termination.json"
    static let launchFileName = "last-launch.json"

    private struct LaunchFile: Codable { let launchID: String }

    private static let settled = OSAllocatedUnfairLock<Previous?>(initialState: nil)

    /// The previous process, as `begin` settled it; nil before `begin` has run (a test, a CLI
    /// subcommand). The orphan sweep reads it for `stop_cause`.
    static var previous: Previous? { settled.withLock { $0 } }

    /// `previous_exit`: `relaunch` when the previous launch asked the agent for a relaunch (UX82
    /// item 1), else its persisted reason (`quit`, `sigterm`); `unclean` when a previous launch is
    /// on record and left no marker (a crash, a kill, a power loss); `first_launch` when none is.
    /// Only `unclean` counts toward `CrashLoopBreaker`.
    static func previousExit(termination: Termination?, previousLaunchID: String?) -> String {
        guard let previousLaunchID else { return termination.map(exitName) ?? "first_launch" }
        guard let termination, termination.launchID == previousLaunchID else { return "unclean" }
        return exitName(termination)
    }

    private static func exitName(_ termination: Termination) -> String {
        termination.relaunch == true ? "relaunch" : termination.reason
    }

    /// `orphan_recording_recovered`'s `stop_cause`: `shutdown` when the stem was the recording open
    /// at the previous process's logged `terminating`, else `unclean_exit`.
    static func orphanStopCause(stem: String, previous: Termination?) -> String {
        previous?.recordingStem == stem ? "shutdown" : "unclean_exit"
    }

    static func terminationURL(in logsDir: URL) -> URL {
        logsDir.appendingPathComponent(terminationFileName)
    }

    /// Write the exit marker. Best effort: a failure costs the next launch's `previous_exit` (it
    /// reads `unclean`), never the exit.
    static func persist(_ termination: Termination, to url: URL) {
        guard let data = try? JSONEncoder().encode(termination) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Settle what the previous launch left and record this one, once per process, at the top of
    /// `App.main` (below the single-instance guard, so a stood-down copy never consumes the
    /// marker the live one needs). Taking the marker here rather than at
    /// `applicationDidFinishLaunching` matters for a launch that crashes before AppKit is up: it
    /// has already replaced the launch id, so the one after it reads `unclean` instead of the
    /// clean exit from two launches back.
    @discardableResult
    static func begin(logsDir: URL = Log.logsDir) -> Previous {
        let markerURL = terminationURL(in: logsDir)
        let launchURL = logsDir.appendingPathComponent(launchFileName)
        let termination = (try? Data(contentsOf: markerURL)).flatMap { try? JSONDecoder().decode(Termination.self, from: $0) }
        try? FileManager.default.removeItem(at: markerURL)
        let previousLaunch = (try? Data(contentsOf: launchURL)).flatMap { try? JSONDecoder().decode(LaunchFile.self, from: $0) }
        if let data = try? JSONEncoder().encode(LaunchFile(launchID: launchID)) {
            try? data.write(to: launchURL, options: .atomic)
        }
        let previous = Previous(
            termination: termination,
            exit: previousExit(termination: termination, previousLaunchID: previousLaunch?.launchID)
        )
        settled.withLock { $0 = previous }
        return previous
    }

    /// The `launched` row's attributes (`launch_id` is stamped by `Log`, so it is not here).
    static func launchedAttributes(
        pid: Int32, cdhash: String?, commit: String?, pipelineCommit: String?, previousExit: String,
        agentJob: Bool = false
    ) -> [String: Any] {
        [
            "pid": Int(pid),
            "agent_job": agentJob,
            "cdhash": cdhash ?? "unknown",
            "commit": commit ?? "unknown",
            "pipeline_commit": pipelineCommit ?? "unknown",
            "previous_exit": previousExit,
        ]
    }

    /// UX82: whether this process is the launch agent's job, the only kind whose non-zero exit
    /// anything answers. launchd names a job's service in `XPC_SERVICE_NAME` (the label); a copy
    /// opened by hand gets Launch Services' `application.<bundle>.<n>.<n>` instead. After a Quit
    /// (exit 0, the default since UX82) and a reopen by hand, the running copy is not supervised:
    /// a requested relaunch would just quit it, and a crash would not bring it back.
    static func isAgentJob(environment: [String: String], label: String = LaunchAtLoginService.label) -> Bool {
        environment["XPC_SERVICE_NAME"] == label
    }

    /// This process, read once.
    static let runsAsAgentJob = isAgentJob(environment: ProcessInfo.processInfo.environment)

    /// The build commits DIST6 item 2 is to stamp into the app's Info.plist; `unknown` until it does.
    static let commitInfoKey = "MPBuildCommit"
    static let pipelineCommitInfoKey = "MPPipelineCommit"

    /// Write `main` / `launched`, once, right after `RebuildTagger.runOnce`.
    static func recordLaunch(
        cdhash: String? = RebuildTagger.currentCDHash(),
        info: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) {
        let exit = (previous ?? begin()).exit
        Log.writeLine("main", "launched (previous exit: \(exit))")
        Log.event(category: "main", action: "launched", attributes: launchedAttributes(
            pid: ProcessInfo.processInfo.processIdentifier,
            cdhash: cdhash,
            commit: info[commitInfoKey] as? String,
            pipelineCommit: info[pipelineCommitInfoKey] as? String,
            previousExit: exit,
            agentJob: runsAsAgentJob
        ))
    }
}
