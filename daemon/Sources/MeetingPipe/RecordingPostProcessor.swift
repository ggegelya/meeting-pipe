import Foundation

/// Everything that happens to a recording's files *after* capture stops (ARCH5).
///
/// Extracted from `MeetingRecorder`, which owned both halves: the live capture graph
/// (AVAudioEngine, the taps, the watchdogs, the mute timeline) and this one, which only
/// ever touches files on disk. The two share no state, which is why the split is a move
/// rather than a rewrite: every member here was already `static`.
///
/// The contract the whole type exists to hold (REC1 / AUD-5 / REC7): a capture
/// intermediate (`<stem>.mic.wav`, `<stem>.system.wav`) is deleted ONLY after a verified
/// promote. ffmpeg writes a `<stem>.merging.wav` temp that is atomically renamed onto the
/// canonical `<stem>.wav` only once it looks plausible, and the ffmpeg wait is bounded, so
/// a killed or timed-out merge can never leave a truncated file at the canonical path that
/// orphan recovery then refuses to touch. Every failure path keeps the intermediates and
/// drops a `<stem>.recordfail.json` breadcrumb, so the next launch's sweep retries.
///
/// Two entry points: `MeetingRecorder.stop()` for the clean path, and `recoverOrphan` for
/// intermediates left behind when `stop()` never ran (crash, kill, rebuild, reinstall).
enum RecordingPostProcessor {

    /// Ceiling on one ffmpeg merge/convert. ScreenCaptureKit and ffmpeg have both
    /// wedged for minutes in the field, and an unbounded wait makes `.stopping`
    /// inescapable; on timeout the merge is abandoned with the intermediates kept.
    private static let mergeCeilingSeconds = 300.0

    // MARK: - Orphan recovery

    /// Reproduce `stop()`'s merge for intermediates left when stop() never
    /// ran (crash, kill, rebuild, reinstall restart): merge mic+system or
    /// mix down a lone side, delete intermediates, return the final URL.
    /// Returns nil if the final `<stem>.wav` exists or neither side has audio.
    static func recoverOrphan(stem: String, in directory: URL) async -> URL? {
        let micURL = directory.appendingPathComponent("\(stem).mic.wav")
        let systemURL = directory.appendingPathComponent("\(stem).system.wav")
        let finalURL = directory.appendingPathComponent("\(stem).wav")
        let fm = FileManager.default

        // Never clobber a recording that already finished.
        guard !fm.fileExists(atPath: finalURL.path) else { return nil }

        let hasMic = fm.fileExists(atPath: micURL.path) && fileSize(micURL) > 4096
        let hasSystem = fm.fileExists(atPath: systemURL.path) && fileSize(systemURL) > 4096
        guard hasMic || hasSystem else { return nil }

        // Same temp+promote path stop() uses (REC7): never delete an unverified
        // merge's inputs, and never leave a truncated final at the canonical path.
        // produceFinal already keeps the intermediates + writes a recordfail
        // breadcrumb on failure, so a later launch retries.
        guard await produceFinal(
            mic: micURL, system: systemURL, final: finalURL, hasMic: hasMic, hasSystem: hasSystem
        ) else {
            Log.writeLine("recorder", "WARN: orphan recovery merge failed for \(stem); kept intermediates for the next launch")
            return nil
        }
        Log.writeLine("recorder", "recovered orphaned recording → \(finalURL.lastPathComponent)")
        return finalURL
    }

    // MARK: - ffmpeg post-process

    /// A finalized WAV must exist and carry more than a bare RIFF/`fmt ` header
    /// before any capture intermediate is deleted. 4 KiB matches the has-audio
    /// threshold the intermediates themselves are gated on (REC1 / AUD-5).
    private static func producedPlausibleOutput(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) && fileSize(url) > 4096
    }

    /// Sidecar dropped beside a recording whose merge/convert failed, so the
    /// retained `.mic.wav` / `.system.wav` read as a kept-for-recovery capture
    /// rather than stray debris. Informational only: the orphan sweep still
    /// retries the merge on the next launch (REC1 / AUD-5).
    static func recordFailURL(forFinal final: URL) -> URL {
        let stem = final.deletingPathExtension().lastPathComponent
        return final.deletingLastPathComponent().appendingPathComponent("\(stem).recordfail.json")
    }

    static func writePostProcessFailure(final: URL, retained: [URL]) {
        let names = retained.map { $0.lastPathComponent }
        let payload: [String: Any] = [
            "schema_version": 1,
            "reason": "ffmpeg post-process failed; capture intermediates were kept for recovery",
            "retained": names,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: recordFailURL(forFinal: final), options: .atomic)
        }
        Log.event(category: "recorder", action: "postprocess_failed", attributes: [
            "file": final.lastPathComponent,
            "retained": names.joined(separator: ","),
        ])
        Log.writeLine("recorder", "ERROR: post-process failed for \(final.lastPathComponent); kept \(names.joined(separator: ", ")) for recovery (REC1)")
    }

    /// Produce the canonical `final` WAV from whichever capture intermediates
    /// exist, reporting whether a usable final landed. REC7: ffmpeg writes a
    /// `<stem>.merging.wav` temp that is atomically promoted onto `final` ONLY once
    /// verified, and the ffmpeg wait is bounded, so a killed or timed-out merge can
    /// never leave a truncated file at the canonical path (which orphan recovery
    /// then refuses to touch). On any failure the intermediates are kept and a
    /// recordfail breadcrumb is dropped so the orphan sweep retries; a consumed
    /// intermediate is deleted only after a verified promote (REC1 / AUD-5). Shared
    /// by `stop()` and `recoverOrphan`. The caller guarantees `hasMic || hasSystem`.
    static func produceFinal(
        mic: URL, system: URL, final: URL, hasMic: Bool, hasSystem: Bool
    ) async -> Bool {
        let tmp = mergingTempURL(forFinal: final)
        // Clear a stale temp a prior abandoned (timed-out) merge may have left.
        try? FileManager.default.removeItem(at: tmp)

        if hasMic && hasSystem {
            if findFFmpeg() == nil {
                // No ffmpeg: move mic -> final (an atomic rename, no wedge risk) and
                // keep system.wav for a later merge or manual recovery.
                Log.writeLine("recorder", "ERROR: ffmpeg not found - moving mic.wav to final, keeping system.wav for a later merge")
                do {
                    try FileManager.default.moveItem(at: mic, to: final)
                } catch {
                    Log.writeLine("recorder", "ERROR: ffmpeg absent and mic.wav could not be moved to final: \(error.localizedDescription)")
                    writePostProcessFailure(final: final, retained: [mic, system])
                    return false
                }
                if producedPlausibleOutput(at: final) { return true }
                writePostProcessFailure(final: final, retained: [mic, system])
                return false
            }
            let finished = await runWithTimeout(seconds: mergeCeilingSeconds) {
                _ = await mergeToTempViaFFmpeg(mic: mic, system: system, tmp: tmp)
            }
            if finished, promoteMerged(tmp: tmp, to: final) {
                try? FileManager.default.removeItem(at: mic)
                try? FileManager.default.removeItem(at: system)
                return true
            }
            writePostProcessFailure(final: final, retained: [mic, system])
            if finished {
                try? FileManager.default.removeItem(at: tmp)
            } else {
                Log.event(category: "recorder", action: "merge_timed_out", attributes: ["file": final.lastPathComponent])
            }
            return false
        }

        // Single source: resample the one present side to 16 kHz mono.
        let source = hasMic ? mic : system
        let finished = await runWithTimeout(seconds: mergeCeilingSeconds) {
            _ = await convertToTempViaFFmpeg(input: source, tmp: tmp)
        }
        if finished, promoteMerged(tmp: tmp, to: final) {
            try? FileManager.default.removeItem(at: mic)
            try? FileManager.default.removeItem(at: system)
            return true
        }
        writePostProcessFailure(final: final, retained: [source])
        if finished {
            try? FileManager.default.removeItem(at: tmp)
        } else {
            Log.event(category: "recorder", action: "merge_timed_out", attributes: ["file": final.lastPathComponent])
        }
        return false
    }

    /// The `<stem>.merging.wav` temp ffmpeg writes to before promotion (REC7), so a
    /// truncated write never lands at the canonical `<stem>.wav`.
    static func mergingTempURL(forFinal final: URL) -> URL {
        final.deletingPathExtension().appendingPathExtension("merging.wav")
    }

    /// Atomically promote a verified temp WAV onto the canonical `final` path (REC7).
    /// Returns false (leaving `final` untouched) when the temp is implausible or the
    /// rename fails, so the caller keeps the intermediates for the orphan sweep.
    private static func promoteMerged(tmp: URL, to final: URL) -> Bool {
        guard producedPlausibleOutput(at: tmp) else { return false }
        try? FileManager.default.removeItem(at: final)
        do {
            try FileManager.default.moveItem(at: tmp, to: final)
        } catch {
            Log.writeLine("recorder", "ERROR: could not promote \(tmp.lastPathComponent) to \(final.lastPathComponent): \(error.localizedDescription)")
            return false
        }
        return producedPlausibleOutput(at: final)
    }

    /// Merge mic + system into a 16 kHz stereo WAV (mic left, system right) written
    /// to `tmp`. Channel separation keeps diarization simple (per-channel RMS
    /// labelling) and makes a missing system channel obvious, instead of the old
    /// mono amix where a silent-system failure looked like "user was the only one
    /// talking" (the May 5 18:30 loss). ffmpeg-only: the absent-ffmpeg fallback is
    /// the caller's concern (its file retention differs). Never touches the final.
    private static func mergeToTempViaFFmpeg(mic: URL, system: URL, tmp: URL) async -> Bool {
        guard let ffmpeg = findFFmpeg() else { return false }
        // Resample mic and system to 16 kHz mono, then amerge into stereo
        // (input 0 -> L, input 1 -> R).
        let filter = """
        [0:a]aresample=16000,aformat=channel_layouts=mono[micL];\
        [1:a]aresample=16000,pan=mono|c0=0.5*c0+0.5*c1[sysR];\
        [micL][sysR]amerge=inputs=2[stereo]
        """
        let args = [
            "-y", "-hide_banner", "-loglevel", "warning",
            "-i", mic.path,
            "-i", system.path,
            "-filter_complex", filter,
            "-map", "[stereo]",
            "-ar", "16000",
            "-c:a", "pcm_s16le",
            tmp.path,
        ]
        let ok = await runFFmpeg(ffmpeg: ffmpeg, args: args, label: "merge")
        return ok && producedPlausibleOutput(at: tmp)
    }

    /// Convert a single-source recording to 16 kHz mono Int16 written to `tmp`.
    /// Used when one capture side is missing. ffmpeg-absent copies the source
    /// as-is (the ASR stack resamples internally).
    private static func convertToTempViaFFmpeg(input: URL, tmp: URL) async -> Bool {
        guard let ffmpeg = findFFmpeg() else {
            try? FileManager.default.copyItem(at: input, to: tmp)
            return producedPlausibleOutput(at: tmp)
        }
        let args = [
            "-y", "-hide_banner", "-loglevel", "warning",
            "-i", input.path,
            "-ac", "1", "-ar", "16000",
            "-c:a", "pcm_s16le",
            tmp.path,
        ]
        let ok = await runFFmpeg(ffmpeg: ffmpeg, args: args, label: "convert")
        return ok && producedPlausibleOutput(at: tmp)
    }

    /// Run ffmpeg and report whether it exited cleanly (status 0). A non-zero
    /// exit or a launch failure returns false so the caller never deletes a
    /// capture intermediate on an unverified merge (REC1 / AUD-5).
    private static func runFFmpeg(ffmpeg: String, args: [String], label: String) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: ffmpeg)
                proc.arguments = args
                // SEC14: ffmpeg needs none of the managed API tokens; don't leak them to the child.
                proc.environment = Secrets.scrubbedEnvironment()
                let errPipe = Pipe()
                proc.standardError = errPipe
                proc.standardOutput = FileHandle.nullDevice
                do {
                    try proc.run()
                } catch {
                    Log.writeLine("recorder", "ERROR ffmpeg \(label) launch: \(error.localizedDescription)")
                    continuation.resume(returning: false)
                    return
                }
                proc.waitUntilExit()
                let stderr = errPipe.fileHandleForReading.availableData
                let tail = String(data: stderr, encoding: .utf8)?
                    .split(separator: "\n").suffix(5).joined(separator: " | ") ?? ""
                Log.writeLine("recorder", "ffmpeg \(label) exit=\(proc.terminationStatus) tail=\(tail)")
                continuation.resume(returning: proc.terminationStatus == 0)
            }
        }
    }

    // MARK: - Utility

    static func fileSize(_ url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    static func findFFmpeg() -> String? {
        // DIST1: a drag-installed self-contained app carries a static ffmpeg under
        // `Contents/Resources/pipeline-runtime/bin/`, so a clean Mac needs no
        // Homebrew ffmpeg. Kept as a fallback (after `MEETINGPIPE_FFMPEG` and PATH)
        // so a machine with its own ffmpeg still uses that; the bundled one is the
        // safety net for a Mac that has none. (DEP1 may later port the merge to
        // native AVFoundation, but MuteRedactor still shells ffmpeg, so the binary
        // does not vanish from a merge-only port.)
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("pipeline-runtime/bin/ffmpeg").path
        return ExecutableResolver.resolve(
            name: "ffmpeg",
            envOverride: "MEETINGPIPE_FFMPEG",
            searchPath: true,
            fallbacks: [bundled, "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
                .compactMap { $0 }
        )
    }

    /// Audio duration in seconds from the RIFF/WAVE header, or nil if absent
    /// or not a PCM WAV. Walks the chunk list rather than assuming a 44-byte
    /// header: AVAudioFile writes extra chunks (JUNK/PEAK/fact) before `data`,
    /// which a fixed-offset parse misread as a zero byte-rate.
    static func audioDurationSec(of url: URL) -> Double? {
        guard FileManager.default.fileExists(atPath: url.path),
              let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        // 8 KB covers the chunk headers before `data` (not the payload).
        guard let head = try? h.read(upToCount: 8192), head.count >= 44 else { return nil }
        guard head.range(of: Data("RIFF".utf8))?.lowerBound == 0,
              head.range(of: Data("WAVE".utf8))?.lowerBound == 8 else { return nil }

        func u32(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= head.count else { return nil }
            return head.subdata(in: offset..<offset + 4)
                .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        func fourCC(_ offset: Int) -> Data? {
            guard offset >= 0, offset + 4 <= head.count else { return nil }
            return head.subdata(in: offset..<offset + 4)
        }

        var byteRate: UInt32?
        var dataSize: UInt32?
        // Chunks after "WAVE": [id(4)][size(4 LE)][body], body even-padded.
        var cursor = 12
        while cursor + 8 <= head.count {
            guard let id = fourCC(cursor), let size = u32(cursor + 4) else { break }
            let body = cursor + 8
            if id == Data("fmt ".utf8) {
                // byteRate is at fmt body offset 8.
                byteRate = u32(body + 8)
            } else if id == Data("data".utf8) {
                dataSize = size
                break
            }
            cursor = body + Int(size) + (Int(size) & 1)
        }

        guard let rate = byteRate, rate > 0, let payload = dataSize else { return nil }
        return Double(payload) / Double(rate)
    }
}
