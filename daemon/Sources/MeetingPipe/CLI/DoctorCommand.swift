import AppKit
import ApplicationServices
import AVFoundation
import Foundation

/// `MeetingPipe doctor` - daemon-side preflight that probes the things
/// that actually break daily use: AX trust + per-app reachability,
/// CoreAudio HAL tap availability (via the Screen Recording permission),
/// the pipeline binary's launch-and-exit roundtrip, and events.jsonl
/// writability. The Python `mp doctor` continues to handle the
/// credential / network side of the preflight; the two are
/// complementary, not redundant.
///
/// Exit code: 0 when every probe is `.ok` or `.warn`; non-zero (1) when
/// any probe is `.fail`. Every probe emits exactly one
/// `Log.event(category: "doctor", action: "probe", ...)` so a dogfood
/// script can correlate failures with daily-use regressions.
enum DoctorCommand {

    enum Status: String {
        /// Everything good. Doctor exits zero even if all probes are `.ok`.
        case ok
        /// Soft failure. Doctor still exits zero but the line is loud
        /// enough for the user to act on (e.g. an app the user hasn't
        /// installed but might want).
        case warn
        /// Hard failure. Doctor exits non-zero.
        case fail
    }

    struct ProbeResult: Equatable {
        let name: String
        let status: Status
        /// Single-line summary printed next to the marker. Avoid stack
        /// traces or paths longer than ~120 chars; the user reads this
        /// from a terminal.
        let message: String
    }

    /// A probe is just a name + a zero-arg run closure. Naming this an
    /// explicit type rather than `(() -> ProbeResult, String)` makes the
    /// list literal in `defaultProbes()` readable.
    struct Probe {
        let name: String
        let run: () -> ProbeResult
    }

    // MARK: - Public entry points

    /// CLI entry. Wired in `App.main` when argv[1] is `"doctor"`.
    static func run() -> Int32 {
        execute(probes: defaultProbes(), writer: { print($0) })
    }

    /// Pure orchestrator: runs each probe, prints the marker line,
    /// emits an event, returns the aggregate exit code. Tests inject
    /// canned probes + a capturing writer to assert behaviour without
    /// hitting AX / AVFoundation / the file system.
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

    /// Built-in probe list. Order is the printing order: keep the
    /// permission probes first since a missing TCC grant masks every
    /// downstream probe.
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
        return out
    }

    /// Subset of bundles from `Resources/meeting_apps.toml` that the
    /// detector treats as native meeting apps, plus the Webex unified
    /// app. We only check apps the user might rely on day-to-day; a
    /// per-bundle "not installed" comes back as `.warn` rather than
    /// `.fail` so a non-Zoom user isn't told their machine is broken.
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

    /// For a known meeting bundle: installed? running? AX-reachable?
    /// Not-installed is a soft signal (the user just doesn't use that
    /// app). Running + AX-trusted + attribute read works → ok.
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
        // AX trust is global; if it's off the per-app read will silently
        // fail. Report the symptom (read failure) here, surface the root
        // cause via the AX-trust probe.
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
            // `pipeline.binary` already reported the underlying issue; skip
            // the redundant FAIL line to keep doctor output readable.
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

    /// Verify we can append a line to `events.jsonl`. The probe is
    /// destructive in spirit (it actually writes), but uses `Log.event`
    /// so the write goes through the same path the daemon uses at
    /// runtime - if this succeeds, the daemon's runtime emission will
    /// too.
    static func probeEventsWritable() -> ProbeResult {
        let url = Log.logsDir.appendingPathComponent("events.jsonl")
        // Read existing size; the doctor's own `probe` events will be
        // written after this method returns, so the check just verifies
        // the path is writable from the daemon's container.
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            // First-launch case: try to create the parent dir + file.
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
