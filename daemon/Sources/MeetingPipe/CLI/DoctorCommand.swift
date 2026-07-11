import AppKit
import ApplicationServices
import AVFoundation
import Foundation

/// `MeetingPipe doctor` - probes AX trust, per-app reachability, Screen Recording / CoreAudio HAL tap, pipeline binary roundtrip, and events.jsonl writability. Complements (not duplicates) `mp doctor`, which handles credentials and network.
/// Exit code: 0 when all probes are `.ok` or `.warn`; 1 on any `.fail`. Each probe emits a `Log.event(category: "doctor", action: "probe")` for dogfood regression tracking.
enum DoctorCommand {

    enum Status: String {
        case ok
        case warn // exits zero, but visible enough for the user to act on
        case fail // exits non-zero
    }

    struct ProbeResult: Equatable {
        let name: String
        let status: Status
        /// Single-line summary. Keep under ~120 chars; avoid stack traces.
        let message: String
    }

    /// Named probe closure. Explicit type (vs a tuple) keeps the `defaultProbes()` list literal readable.
    struct Probe {
        let name: String
        let run: () -> ProbeResult
    }

    // MARK: - Public entry points

    /// CLI entry point; wired in `App.main` when argv[1] is `"doctor"`.
    static func run() -> Int32 {
        execute(probes: defaultProbes(), writer: { print($0) })
    }

    /// Pure orchestrator: runs each probe, prints its marker line, emits an event, and returns the aggregate exit code. Tests inject canned probes + a capturing writer to avoid hitting AX / AVFoundation / the file system.
    @discardableResult
    static func execute(
        probes: [Probe],
        writer: (String) -> Void
    ) -> Int32 {
        var hardFails = 0
        for probe in probes {
            let result = probe.run()
            writer(formatLine(result))
            Log.event(category: "doctor", action: "probe", attributes: [
                "name": result.name,
                "status": result.status.rawValue,
                "message": result.message,
            ])
            if result.status == .fail { hardFails += 1 }
        }
        writer("")
        if hardFails == 0 {
            writer("doctor: all probes passed.")
            return 0
        }
        writer("doctor: \(hardFails) probe\(hardFails == 1 ? "" : "s") failed.")
        return 1
    }

    static func formatLine(_ r: ProbeResult) -> String {
        let marker: String
        switch r.status {
        case .ok: marker = "[ OK ]"
        case .warn: marker = "[WARN]"
        case .fail: marker = "[FAIL]"
        }
        return "\(marker) \(r.name): \(r.message)"
    }

    // MARK: - Probe set

    /// Built-in probe list. Permission probes run first - a missing TCC grant masks all downstream probes.
    static func defaultProbes() -> [Probe] {
        var out: [Probe] = [
            Probe(name: "accessibility.trusted", run: probeAXTrust),
            Probe(name: "permission.screen_recording", run: probeScreenRecording),
            Probe(name: "permission.microphone", run: probeMicrophone),
        ]
        for bundleID in knownMeetingBundleIDs {
            out.append(Probe(name: "ax.app.\(bundleID)") { probeAppReachable(bundleID: bundleID) })
        }
        out.append(Probe(name: "pipeline.binary", run: probePipelineBinary))
        out.append(Probe(name: "pipeline.roundtrip", run: probePipelineRoundtrip))
        out.append(Probe(name: "events.writable", run: probeEventsWritable))
        out.append(Probe(name: "library.orphans", run: probeOrphans))
        return out
    }

    /// The probes unique to the daemon (AX trust, TCC permissions, per-app AX
    /// reachability, events writability, orphan scan) - the ones `mp doctor`
    /// cannot run. Excludes the `pipeline.*` probes, which the Preferences doctor
    /// already exercises by spawning `mp doctor` alongside this (UX20 fold). Fast
    /// enough to run inline on the main thread (no `pipeline.roundtrip` spawn).
    static func daemonSelfCheckProbes() -> [Probe] {
        var out: [Probe] = [
            Probe(name: "accessibility.trusted", run: probeAXTrust),
            Probe(name: "permission.screen_recording", run: probeScreenRecording),
            Probe(name: "permission.microphone", run: probeMicrophone),
        ]
        for bundleID in knownMeetingBundleIDs {
            out.append(Probe(name: "ax.app.\(bundleID)") { probeAppReachable(bundleID: bundleID) })
        }
        out.append(Probe(name: "events.writable", run: probeEventsWritable))
        out.append(Probe(name: "library.orphans", run: probeOrphans))
        return out
    }

    /// Meeting apps to probe (subset of `meeting_apps.toml` native apps + Webex unified). "Not installed" is `.warn` so a non-Zoom user isn't told their machine is broken.
    static let knownMeetingBundleIDs: [String] = [
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "us.zoom.xos",
        "com.tinyspeck.slackmacgap",
        "com.cisco.webexmeetingsapp",
        "com.cisco.spark",
    ]

    // MARK: - Individual probes

    static func probeAXTrust() -> ProbeResult {
        let trusted = AXIsProcessTrusted()
        if trusted {
            return ProbeResult(
                name: "accessibility.trusted",
                status: .ok,
                message: "AX granted; per-app probes can proceed."
            )
        }
        return ProbeResult(
            name: "accessibility.trusted",
            status: .fail,
            message: "AX not granted. System Settings → Privacy & Security → Accessibility → MeetingPipe."
        )
    }

    static func probeScreenRecording() -> ProbeResult {
        switch SystemAudioCapture.permissionState {
        case .granted:
            return ProbeResult(
                name: "permission.screen_recording",
                status: .ok,
                message: "ScreenCaptureKit reachable; system audio capture works."
            )
        case .denied:
            return ProbeResult(
                name: "permission.screen_recording",
                status: .fail,
                message: "Screen Recording denied; mic-only recordings only. Open System Settings → Privacy & Security → Screen Recording."
            )
        case .unknown:
            return ProbeResult(
                name: "permission.screen_recording",
                status: .warn,
                message: "ScreenCaptureKit not prewarmed yet; daemon may not have run since reboot."
            )
        }
    }

    static func probeMicrophone() -> ProbeResult {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return ProbeResult(
                name: "permission.microphone",
                status: .ok,
                message: "Mic permission granted."
            )
        case .denied, .restricted:
            return ProbeResult(
                name: "permission.microphone",
                status: .fail,
                message: "Mic permission denied. Recordings will be silent."
            )
        case .notDetermined:
            return ProbeResult(
                name: "permission.microphone",
                status: .warn,
                message: "Mic permission not yet requested. Start a recording or run the daemon once to surface the prompt."
            )
        @unknown default:
            return ProbeResult(
                name: "permission.microphone",
                status: .warn,
                message: "Mic permission status not recognised by this macOS build."
            )
        }
    }

    /// Probe: is the app installed? Running? AX-reachable? Not-installed is `.warn` (user just doesn't use that app).
    static func probeAppReachable(bundleID: String) -> ProbeResult {
        let name = "ax.app.\(bundleID)"
        let workspace = NSWorkspace.shared
        let installed = workspace.urlForApplication(withBundleIdentifier: bundleID) != nil
        if !installed {
            return ProbeResult(name: name, status: .warn, message: "Not installed.")
        }
        let runningPID = workspace.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID })?.processIdentifier
        guard let pid = runningPID else {
            return ProbeResult(name: name, status: .ok, message: "Installed; not currently running (probe skipped).")
        }
        // AX trust is global; a missing grant silently fails per-app reads. Report the symptom here; the AX-trust probe surfaces the root cause.
        let app = AXUIElementCreateApplication(pid)
        var titleRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXTitleAttribute as CFString, &titleRef)
        switch err {
        case .success, .noValue, .attributeUnsupported:
            return ProbeResult(name: name, status: .ok, message: "Reachable (pid \(pid)).")
        case .apiDisabled, .invalidUIElement, .cannotComplete, .notImplemented:
            return ProbeResult(
                name: name,
                status: .fail,
                message: "AX read failed (\(err.rawValue)); confirm `accessibility.trusted` is `[ OK ]`."
            )
        default:
            return ProbeResult(
                name: name,
                status: .fail,
                message: "AX read returned unexpected error \(err.rawValue)."
            )
        }
    }

    static func probePipelineBinary() -> ProbeResult {
        guard let mp = PipelineLauncher.findMP() else {
            return ProbeResult(
                name: "pipeline.binary",
                status: .fail,
                message: "`mp` not found. Did scripts/install.sh complete?"
            )
        }
        return ProbeResult(
            name: "pipeline.binary",
            status: .ok,
            message: "Found at \(mp.shell)."
        )
    }

    static func probePipelineRoundtrip() -> ProbeResult {
        guard let mp = PipelineLauncher.findMP() else {
            // `pipeline.binary` already reported the root cause; skip the redundant FAIL line.
            return ProbeResult(
                name: "pipeline.roundtrip",
                status: .fail,
                message: "Skipped (see `pipeline.binary` above)."
            )
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: mp.shell)
        process.arguments = mp.args + ["--help"]
        process.environment = PipelineLauncher.freshEnvironment()
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = outPipe
        do {
            try process.run()
        } catch {
            return ProbeResult(
                name: "pipeline.roundtrip",
                status: .fail,
                message: "Spawn failed: \(error.localizedDescription)."
            )
        }
        let timeout: TimeInterval = 10
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return ProbeResult(
                name: "pipeline.roundtrip",
                status: .fail,
                message: "`mp --help` did not exit within \(Int(timeout)) s."
            )
        }
        if process.terminationStatus != 0 {
            return ProbeResult(
                name: "pipeline.roundtrip",
                status: .fail,
                message: "`mp --help` exited \(process.terminationStatus)."
            )
        }
        return ProbeResult(
            name: "pipeline.roundtrip",
            status: .ok,
            message: "`mp --help` exited 0."
        )
    }

    /// Surface recordings the library can't pair with a row, and rows with no wav. `.warn` only - orphans don't block daily use but the message gives a cleanup starting point.
    static func probeOrphans() -> ProbeResult {
        let dir = resolveRecordingsDir()
        let report = OrphanScan.scan(directory: dir)
        if report.isEmpty {
            return ProbeResult(
                name: "library.orphans",
                status: .ok,
                message: "No orphaned recordings or sidecars in \(dir.path)."
            )
        }
        return ProbeResult(
            name: "library.orphans",
            status: .warn,
            message: formatOrphanMessage(report, dir: dir)
        )
    }

    static func formatOrphanMessage(_ report: OrphanScan.Report, dir: URL) -> String {
        var parts: [String] = []
        if !report.wavsWithoutRow.isEmpty {
            let stems = report.wavsWithoutRow.prefix(5).map { $0.stem }
            let suffix = report.wavsWithoutRow.count > 5 ? ", …" : ""
            parts.append(
                "\(report.wavsWithoutRow.count) wav(s) the library can't index: "
                + "\(stems.joined(separator: ", "))\(suffix)"
            )
        }
        if !report.rowsWithoutWav.isEmpty {
            let stems = report.rowsWithoutWav.prefix(5).map { $0.stem }
            let suffix = report.rowsWithoutWav.count > 5 ? ", …" : ""
            parts.append(
                "\(report.rowsWithoutWav.count) stem(s) with sidecars but no wav: "
                + "\(stems.joined(separator: ", "))\(suffix)"
            )
        }
        return parts.joined(separator: "; ") + " (in \(dir.path))"
    }

    /// Reproduce `Coordinator`'s recordings-dir lookup. TOML failures fall back to the same default the daemon uses at first launch.
    static func resolveRecordingsDir() -> URL {
        do {
            return try Config.load().recording.outputDir
        } catch {
            return Config.defaultFallback().recording.outputDir
        }
    }

    /// Verify `events.jsonl` is writable. Actually creates the file if absent, using the same path as the daemon at runtime; if this succeeds, runtime emission will too.
    static func probeEventsWritable() -> ProbeResult {
        let url = Log.logsDir.appendingPathComponent("events.jsonl")
        // The doctor's own `probe` events are written after this returns, so this just verifies the path is writable in the daemon's container.
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            // First launch: create parent dir + file.
            do {
                try fm.createDirectory(at: Log.logsDir, withIntermediateDirectories: true)
                try Data().write(to: url, options: .atomic)
            } catch {
                return ProbeResult(
                    name: "events.writable",
                    status: .fail,
                    message: "Cannot create \(url.path): \(error.localizedDescription)."
                )
            }
        }
        if !fm.isWritableFile(atPath: url.path) {
            return ProbeResult(
                name: "events.writable",
                status: .fail,
                message: "\(url.path) is not writable."
            )
        }
        return ProbeResult(
            name: "events.writable",
            status: .ok,
            message: "\(url.path) writable."
        )
    }
}
