import AppKit
import ApplicationServices
import AVFoundation
import Foundation
import MeetingPipeCore

/// `MeetingPipe doctor` - probes AX trust, per-app reachability, Screen Recording / CoreAudio HAL tap, the app's resource bundles, pipeline binary roundtrip, and events.jsonl writability. Complements (not duplicates) `mp doctor`, which handles credentials and network.
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
    /// `@Sendable` because the in-app doctor runs the list off main (PERF24).
    struct Probe {
        let name: String
        let run: @Sendable () -> ProbeResult
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
            writer(record(result))
            if result.status == .fail { hardFails += 1 }
        }
        for line in summaryLines(hardFails: hardFails) { writer(line) }
        return hardFails == 0 ? 0 : 1
    }

    /// The per-result step, shared with `DoctorRunner`, which runs the probes off main and
    /// hands each result back to main for this (PERF24): emits the probe event and returns the
    /// marker line.
    static func record(_ result: ProbeResult) -> String {
        Log.event(category: "doctor", action: "probe", attributes: [
            "name": result.name,
            "status": result.status.rawValue,
            "message": result.message,
        ])
        return formatLine(result)
    }

    /// The blank line and the verdict that close a run.
    static func summaryLines(hardFails: Int) -> [String] {
        if hardFails == 0 { return ["", "doctor: all probes passed."] }
        return ["", "doctor: \(hardFails) probe\(hardFails == 1 ? "" : "s") failed."]
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
            Probe(name: "accessibility.trusted", run: { probeAXTrust() }),
            Probe(name: "permission.screen_recording", run: { probeScreenRecording() }),
            Probe(name: "permission.microphone", run: { probeMicrophone() }),
        ]
        for bundleID in knownMeetingBundleIDs {
            out.append(Probe(name: "ax.app.\(bundleID)") { probeAppReachable(bundleID: bundleID) })
        }
        out.append(Probe(name: "app.resources", run: { probeResources() }))
        out.append(Probe(name: "pipeline.binary", run: { probePipelineBinary() }))
        out.append(Probe(name: "pipeline.roundtrip", run: { probePipelineRoundtrip() }))
        out.append(Probe(name: "events.writable", run: { probeEventsWritable() }))
        out.append(Probe(name: "library.orphans", run: { probeOrphans() }))
        out.append(Probe(name: "search.index", run: { probeSearchIndex() }))
        return out
    }

    /// The probes unique to the daemon (AX trust, TCC permissions, resource bundles, per-app AX
    /// reachability, events writability, orphan scan) - the ones `mp doctor`
    /// cannot run. Excludes the `pipeline.*` probes, which the Preferences doctor
    /// already exercises by spawning `mp doctor` alongside this (UX20 fold). No
    /// `pipeline.roundtrip` spawn, but not cheap enough for the main thread either:
    /// each running meeting app costs an AX round-trip (up to the process-wide 2 s
    /// messaging timeout when the app is hung), plus a `raw/` scan and a second
    /// SQLite connection, so `DoctorRunner` runs the list on a utility queue (PERF24).
    static func daemonSelfCheckProbes() -> [Probe] {
        var out: [Probe] = [
            Probe(name: "accessibility.trusted", run: { probeAXTrust() }),
            Probe(name: "permission.screen_recording", run: { probeScreenRecording() }),
            Probe(name: "permission.microphone", run: { probeMicrophone() }),
        ]
        for bundleID in knownMeetingBundleIDs {
            out.append(Probe(name: "ax.app.\(bundleID)") { probeAppReachable(bundleID: bundleID) })
        }
        out.append(Probe(name: "app.resources", run: { probeResources() }))
        out.append(Probe(name: "events.writable", run: { probeEventsWritable() }))
        out.append(Probe(name: "library.orphans", run: { probeOrphans() }))
        out.append(Probe(name: "search.index", run: { probeSearchIndex() }))
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

    /// DIST4: the resource bundles load from where the installed app keeps them (`Contents/Resources`). An `.app` assembled without them no longer crashes (`ResourceBundleLocator` degrades to empty lookups), so this is where that shows up: a `.fail` naming each missing resource. Inputs injectable so both outcomes unit-test.
    static func probeResources(
        loadMuteLabels: () throws -> Void = { _ = try MuteLabelsLoader.loadDefault() },
        appBundle: Bundle = .appResources
    ) -> ProbeResult {
        var missing: [String] = []
        do { try loadMuteLabels() } catch { missing.append("MuteLabels.toml (\(error.localizedDescription))") }
        if appBundle.url(forResource: "meeting_apps", withExtension: "toml") == nil { missing.append("meeting_apps.toml") }
        if appBundle.url(forResource: "_fallback", withExtension: "svg") == nil { missing.append("_fallback.svg") }
        guard missing.isEmpty else {
            return ProbeResult(
                name: "app.resources",
                status: .fail,
                message: "Missing \(missing.joined(separator: ", ")) from \(appBundle.bundlePath). Re-run scripts/install.sh."
            )
        }
        return ProbeResult(name: "app.resources", status: .ok, message: "Loaded from \(appBundle.bundlePath).")
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

    /// Reproduce `Coordinator`'s recordings-dir lookup. A file that does not parse yields the same default the daemon falls back to (ARCH9).
    static func resolveRecordingsDir() -> URL {
        ConfigStore().config.recording.outputDir
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

    /// Report whether Library search has its full-text depth (UX23). A `.fail` is the permanent
    /// degraded case (FTS5 is not compiled into the linked SQLite, or the cache cannot be read),
    /// where search silently falls back to titles + summaries only.
    ///
    /// PERF20: reachable is not the same as caught up. The probe reported ok with "0 meetings
    /// indexed" 19 times in a day beside a 9-meeting library, so it now compares the index with
    /// the library's `<stem>.md` transcripts and warns, naming both counts, when any transcript is
    /// not indexed.
    ///
    /// Read-only (`SearchIndex.inspect`): a diagnostic never creates, migrates or rebuilds the
    /// cache. Opening it through `SearchIndex(url:)` once let a newer build's doctor migrate the
    /// cache of a running older daemon (2026-11-12).
    static func probeSearchIndex(
        indexURL: URL = SearchIndexer.defaultIndexURL(),
        recordingsDir: URL? = nil
    ) -> ProbeResult {
        guard SearchIndex.fts5Available() else {
            return ProbeResult(
                name: "search.index",
                status: .fail,
                message: "The linked SQLite has no FTS5; Library search is limited to titles and summaries."
            )
        }
        let indexed: Set<String>
        let reachable: String
        switch SearchIndex.inspect(url: indexURL) {
        case .unreadable:
            return ProbeResult(
                name: "search.index",
                status: .fail,
                message: "FTS index could not be read at \(indexURL.path); Library search is limited to titles and summaries."
            )
        case .otherSchema(let version):
            return ProbeResult(
                name: "search.index",
                status: .warn,
                message: "FTS index at \(indexURL.path) is schema \(version), this build uses schema "
                    + "\(SearchIndex.schemaVersion); it is rebuilt when this build's Library opens it. Doctor leaves it as is."
            )
        case .absent:
            indexed = []
            reachable = "FTS index not built yet"
        case .indexed(let stems):
            indexed = stems
            reachable = "FTS index reachable"
        }
        let indexedText = "\(indexed.count) meeting\(indexed.count == 1 ? "" : "s") indexed"
        let dir = recordingsDir ?? resolveRecordingsDir()
        guard let transcripts = transcriptStems(in: dir) else {
            // An unreadable library is STOR11's probe to report; there is nothing to compare here.
            return ProbeResult(name: "search.index", status: .ok, message: "\(reachable); \(indexedText).")
        }
        let missing = transcripts.subtracting(indexed)
        if missing.isEmpty {
            return ProbeResult(name: "search.index", status: .ok, message: "\(reachable); \(indexedText).")
        }
        let sample = missing.sorted().prefix(3).joined(separator: ", ")
        let more = missing.count > 3 ? ", …" : ""
        return ProbeResult(
            name: "search.index",
            status: .warn,
            message: "FTS index has \(indexedText), but \(missing.count) of the library's \(transcripts.count) "
                + "transcript\(transcripts.count == 1 ? "" : "s") are not indexed (\(sample)\(more)); "
                + "opening the Library or Quick Find indexes them."
        )
    }

    /// Stems with a `<stem>.md` transcript in `dir` (exactly that name, never another `.md`
    /// sidecar), limited to stems the Library recognises as meetings. Nil when `dir` cannot be
    /// listed.
    static func transcriptStems(in dir: URL) -> Set<String>? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        var stems = Set<String>()
        for name in names {
            let stem = MeetingStore.stem(of: dir.appendingPathComponent(name))
            guard name == "\(stem).md", MeetingStore.parseStem(stem) != nil else { continue }
            stems.insert(stem)
        }
        return stems
    }
}
