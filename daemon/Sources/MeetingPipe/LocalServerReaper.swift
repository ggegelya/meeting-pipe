import Foundation

/// Reaps an `mlx_lm.server` that outlived the `mp` process which spawned it (LOCAL10).
///
/// The pipeline's `LocalSummaryClient` starts the model server with `setsid`, so it
/// sits in its own session and a signal aimed at `mp`'s process group cannot reach
/// it. Every clean exit path in `mp` kills it. The one path that does not is
/// `PipelineLauncher`'s watchdog SIGKILLing a wedged `run-all` (the LOCAL2/AUD-21
/// scenario the watchdog exists for): the parent's idle-timeout timer dies with the
/// parent, and a multi-GB server is left resident with nothing that knows it exists.
///
/// Python leaves us a marker naming it (`mp.local_server`, schema in CONVENTIONS.md).
/// We reap on two triggers: at launch, in `Coordinator.reapStorage()`'s sweep, and
/// immediately after the watchdog kills a job, which is the case that creates the
/// orphan in the first place.
///
/// `mp serve-local` writes no marker. The daemon spawns it directly and owns its
/// lifetime through a child handle, so it can never be orphaned this way.
enum LocalServerReaper {

    /// What Python wrote at spawn. `ownerPID` is the `mp` process that owns the server.
    struct Marker: Equatable {
        let pid: pid_t
        let ownerPID: pid_t
        let model: String
        let port: Int
    }

    static var markerURL: URL {
        Log.logsDir.appendingPathComponent("mlx-server.json")
    }

    /// Reap an orphaned server if there is one. Safe to call when there is not:
    /// a missing marker, a dead server, or a live owner all no-op.
    ///
    /// Not `@MainActor`: called from a background sweep and from the launcher's
    /// watchdog queue. Touches only the filesystem and `kill(2)`.
    @discardableResult
    static func reapIfOrphaned() -> Marker? {
        guard let marker = loadMarker() else { return nil }

        guard isServerAlive(marker.pid) else {
            // Stale marker: the server is already gone. Clear it so `mp doctor`
            // does not report a ghost.
            try? FileManager.default.removeItem(at: markerURL)
            return nil
        }
        guard !isOwnerAlive(marker.ownerPID) else {
            return nil  // a live `mp` is mid-summarize; its own close() will reap this
        }

        Log.writeLine("main", "Reaping orphaned mlx_lm.server (pid \(marker.pid), model \(marker.model))")
        Log.event(category: "pipeline", action: "local_server_reaped", attributes: [
            "pid": Int(marker.pid),
            "model": marker.model,
            "port": marker.port,
        ])

        // Signal the process group: the server setsid'd, so its group id equals its
        // pid and any worker it forked dies with it.
        if killpg(marker.pid, SIGTERM) != 0 {
            kill(marker.pid, SIGTERM)
        }
        for _ in 0..<20 {  // up to ~10 s for a graceful exit
            Thread.sleep(forTimeInterval: 0.5)
            if !isServerAlive(marker.pid) { break }
        }
        if isServerAlive(marker.pid), killpg(marker.pid, SIGKILL) != 0 {
            kill(marker.pid, SIGKILL)
        }

        try? FileManager.default.removeItem(at: markerURL)
        return marker
    }

    // MARK: - Marker

    /// Pure decode, split from the file read so tests need no filesystem.
    /// Missing `pid` or `owner_pid` is a marker we cannot act on: nil.
    static func parseMarker(_ data: Data) -> Marker? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = obj["pid"] as? Int,
              let ownerPID = obj["owner_pid"] as? Int
        else { return nil }
        return Marker(
            pid: pid_t(pid),
            ownerPID: pid_t(ownerPID),
            model: obj["model"] as? String ?? "unknown",
            port: obj["port"] as? Int ?? 0
        )
    }

    static func loadMarker() -> Marker? {
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        return parseMarker(data)
    }

    // MARK: - Process identity
    //
    // Pure predicates over a `ps` command line, so the reap decision is testable
    // without a process table. They mirror `mp.local_server`'s rules exactly; the
    // two sides have to agree on what counts as alive or the daemon and `doctor`
    // will disagree about the same marker.

    /// A recycled pid must never be signalled, so identity, not liveness, is the gate.
    static func isServerCommand(_ command: String?) -> Bool {
        command?.contains("mlx_lm.server") ?? false
    }

    /// A pid whose command is not a Python `mp` invocation reads as a dead owner,
    /// so pid reuse cannot hide an orphan behind a live-looking owner.
    static func isOwnerCommand(_ command: String?) -> Bool {
        guard let command else { return false }
        return command.contains("mp") || command.lowercased().contains("python")
    }

    static func isServerAlive(_ pid: pid_t) -> Bool {
        isServerCommand(commandLine(of: pid))
    }

    static func isOwnerAlive(_ pid: pid_t) -> Bool {
        isOwnerCommand(commandLine(of: pid))
    }

    /// `ps -o command= -p <pid>`, or nil when the process does not exist.
    /// Matches the identity test `mp.local_server.pid_command` runs, so the two
    /// sides agree on what counts as alive.
    private static func commandLine(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-o", "command=", "-p", String(pid)]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }
}
