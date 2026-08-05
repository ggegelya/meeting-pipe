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
/// "Looks plausible" is a duration check since REC9, not a byte count. The merge runs
/// under an explicit length policy (`mergeLengths`) so the final is never shorter than
/// the longer capture channel, and the promote gate re-measures the result against that
/// target; the byte floor alone waved through a merge that kept 5.28 s of a 41.2 s
/// meeting on 2026-07-15 and then deleted the only copies of the rest.
///
/// Two entry points: `MeetingRecorder.stop()` for the clean path, and `recoverOrphan` for
/// intermediates left behind when `stop()` never ran (crash, kill, rebuild, reinstall).
enum RecordingPostProcessor {

    /// Ceiling on one ffmpeg merge/convert. ScreenCaptureKit and ffmpeg have both
    /// wedged for minutes in the field, and an unbounded wait makes `.stopping`
    /// inescapable; on timeout the merge is abandoned with the intermediates kept.
    private static let mergeCeilingSeconds = 300.0

    /// How much shorter than its expected length a produced final may be and still
    /// be promoted (REC9). The merge is cut with an explicit `-t`, so a healthy
    /// output lands on its target to within a frame or two; this is slack for
    /// resampler rounding, not a budget for lost audio. Anything below it is a
    /// truncation, and truncation is what destroyed 87% of the 2026-07-15 meeting.
    static let durationToleranceSec = 0.5

    /// A measured system-channel head offset below this is the routine capture skew
    /// (CAP1: median 0.21 s across the owner's 153 recordings) and is left alone, so
    /// the fix for a late-starting channel cannot perturb the alignment of every
    /// normal recording. Above it the offset is real: on 2026-07-15 system capture
    /// came up 35.9 s into a 41.2 s meeting.
    static let systemHeadOffsetFloorSec = 1.0

    // MARK: - Merge length policy (REC9)

    /// The explicit length policy one merge runs under.
    ///
    /// `amerge` has no length option at all (`ffmpeg -h filter=amerge` on 8.1 lists
    /// only `inputs` and `layout_mode`), so its output ends where the **shorter**
    /// input ends. The bare filter therefore truncated the final to whichever
    /// capture channel was shorter, which was the system channel on 140 of the
    /// owner's 153 recordings, and `produceFinal` then deleted both intermediates.
    /// The policy fixes the length in two places instead: `apad` on each leg so
    /// neither can end the merge, and an explicit `-t` cut at the target.
    ///
    /// Padding the tail is not sufficient on its own. A channel that started late
    /// carries audio for the END of the meeting, so merging it at sample 0 lands
    /// every recovered word against the wrong mic timestamps; `systemDelayMs` is
    /// the `adelay` that puts it back where it was captured.
    struct MergeLengths: Equatable {
        /// Silence prepended to the system leg, in milliseconds (`adelay`'s unit).
        var systemDelayMs: Int
        /// Whether the mic leg is padded too. Only safe alongside `targetDurationSec`:
        /// padding both legs with no cut makes the merge infinite.
        var padMic: Bool
        /// What the output is cut to (`-t`), or nil when the durations needed to
        /// compute it could not be read.
        var targetDurationSec: Double?
        /// The length the produced final is checked against before promotion, or nil
        /// when nothing about the inputs could be measured (byte floor only).
        var expectedDurationSec: Double?

        /// The system leg's `adelay`, as seconds, for logging.
        var systemDelaySec: Double { Double(systemDelayMs) / 1000.0 }
    }

    /// Decide one merge's length policy. Pure, so the arithmetic is testable without
    /// ffmpeg or a recording.
    ///
    /// With both durations in hand the target is `max(mic, offset + system)`: never
    /// shorter than the longer capture channel, which is the whole point. When a
    /// duration cannot be read the fallback pads only the system leg and sets no
    /// cut, so the merge ends with the **mic**: a deliberate bias, since the mic is
    /// the channel the owner cannot re-obtain, and it is still strictly longer than
    /// the `min()` the bare filter produced.
    static func mergeLengths(
        micDurationSec: Double?,
        systemDurationSec: Double?,
        systemHeadOffsetSec: Double
    ) -> MergeLengths {
        let offset = systemHeadOffsetSec >= systemHeadOffsetFloorSec ? systemHeadOffsetSec : 0
        let delayMs = Int((offset * 1000).rounded())
        guard let mic = micDurationSec, let system = systemDurationSec else {
            return MergeLengths(
                systemDelayMs: delayMs,
                padMic: false,
                targetDurationSec: nil,
                expectedDurationSec: micDurationSec
            )
        }
        let target = max(mic, offset + system)
        return MergeLengths(
            systemDelayMs: delayMs,
            padMic: true,
            targetDurationSec: target,
            expectedDurationSec: target
        )
    }

    /// Whether a produced artifact may be promoted, given what the inputs said it
    /// should be (REC9). Pure half of `producedPlausibleOutput`.
    ///
    /// The byte floor is REC1's: more than a bare RIFF/`fmt ` header, matching the
    /// has-audio threshold the intermediates are gated on. It is necessary and was
    /// never sufficient, since the 2026-07-15 truncation passed it at 192 KB. An
    /// expected length that cannot be checked against a produced one fails closed:
    /// the caller keeps both intermediates and drops a breadcrumb, which costs a
    /// retry, where promoting costs the meeting.
    static func outputIsPlausible(
        byteCount: UInt64,
        producedDurationSec: Double?,
        expectedDurationSec: Double?
    ) -> Bool {
        guard byteCount > 4096 else { return false }
        guard let expected = expectedDurationSec, expected > 0 else { return true }
        guard let produced = producedDurationSec else { return false }
        return produced + durationToleranceSec >= expected
    }

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

    /// A finalized WAV must exist, carry more than a bare RIFF/`fmt ` header, and
    /// (REC9) be as long as the capture it was built from, before any capture
    /// intermediate is deleted. Internal rather than private so the fail-closed
    /// duration refusal can be pinned against a real file on disk.
    ///
    /// `expectedDurationSec` is nil only where nothing about the inputs could be
    /// measured; then this degrades to REC1's byte floor.
    static func producedPlausibleOutput(at url: URL, expectedDurationSec: Double? = nil) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        // Only read the header when there is something to compare it against.
        let produced = expectedDurationSec == nil ? nil : audioDurationSec(of: url)
        return outputIsPlausible(
            byteCount: fileSize(url),
            producedDurationSec: produced,
            expectedDurationSec: expectedDurationSec
        )
    }

    /// Sidecar dropped beside a recording whose merge/convert failed, so the
    /// retained `.mic.wav` / `.system.wav` read as a kept-for-recovery capture
    /// rather than stray debris. Informational only: the orphan sweep still
    /// retries the merge on the next launch (REC1 / AUD-5).
    static func recordFailURL(forFinal final: URL) -> URL {
        let stem = final.deletingPathExtension().lastPathComponent
        return final.deletingLastPathComponent().appendingPathComponent("\(stem).recordfail.json")
    }

    static func writePostProcessFailure(
        final: URL,
        retained: [URL],
        reason: String = "ffmpeg post-process failed; capture intermediates were kept for recovery"
    ) {
        let names = retained.map { $0.lastPathComponent }
        let payload: [String: Any] = [
            "schema_version": 1,
            "reason": reason,
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
    ///
    /// `systemHeadOffsetSec` (REC9) is how long after the mic started the system
    /// channel's first frame landed, so a capture that came up late is merged where
    /// it was recorded instead of at sample 0. `stop()` measures it; `recoverOrphan`
    /// passes 0, because a crash leaves no record of when either channel began.
    static func produceFinal(
        mic: URL, system: URL, final: URL, hasMic: Bool, hasSystem: Bool,
        systemHeadOffsetSec: Double = 0
    ) async -> Bool {
        let tmp = mergingTempURL(forFinal: final)
        // Clear a stale temp a prior abandoned (timed-out) merge may have left.
        try? FileManager.default.removeItem(at: tmp)

        if hasMic && hasSystem {
            let lengths = mergeLengths(
                micDurationSec: audioDurationSec(of: mic),
                systemDurationSec: audioDurationSec(of: system),
                systemHeadOffsetSec: systemHeadOffsetSec
            )
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
                // Byte floor only, deliberately. Nothing merged: this is the mic file
                // under a new name, so `lengths`' target (which counts system audio
                // that is still sitting in `system.wav`) is not a length it could ever
                // have, and checking it against its own duration would assert nothing.
                if producedPlausibleOutput(at: final) { return true }
                writePostProcessFailure(final: final, retained: [mic, system])
                return false
            }
            let finished = await runWithTimeout(seconds: mergeCeilingSeconds) {
                _ = await mergeToTempViaFFmpeg(mic: mic, system: system, tmp: tmp, lengths: lengths)
            }
            if finished, promoteMerged(tmp: tmp, to: final, expectedDurationSec: lengths.expectedDurationSec) {
                try? FileManager.default.removeItem(at: mic)
                try? FileManager.default.removeItem(at: system)
                return true
            }
            writePostProcessFailure(
                final: final,
                retained: [mic, system],
                reason: mergeFailureReason(tmp: tmp, expectedDurationSec: lengths.expectedDurationSec, finished: finished)
            )
            if finished {
                try? FileManager.default.removeItem(at: tmp)
            } else {
                Log.event(category: "recorder", action: "merge_timed_out", attributes: ["file": final.lastPathComponent])
            }
            return false
        }

        // Single source: resample the one present side to 16 kHz mono.
        let source = hasMic ? mic : system
        let sourceDurationSec = audioDurationSec(of: source)
        let finished = await runWithTimeout(seconds: mergeCeilingSeconds) {
            _ = await convertToTempViaFFmpeg(input: source, tmp: tmp, expectedDurationSec: sourceDurationSec)
        }
        if finished, promoteMerged(tmp: tmp, to: final, expectedDurationSec: sourceDurationSec) {
            try? FileManager.default.removeItem(at: mic)
            try? FileManager.default.removeItem(at: system)
            return true
        }
        writePostProcessFailure(
            final: final,
            retained: [source],
            reason: mergeFailureReason(tmp: tmp, expectedDurationSec: sourceDurationSec, finished: finished)
        )
        if finished {
            try? FileManager.default.removeItem(at: tmp)
        } else {
            Log.event(category: "recorder", action: "merge_timed_out", attributes: ["file": final.lastPathComponent])
        }
        return false
    }

    /// Why a post-process did not promote, for the breadcrumb's `reason` (REC9).
    /// A too-short output is a different failure from a dead or wedged ffmpeg, and
    /// the breadcrumb is all a later reader (or the owner) has to go on.
    private static func mergeFailureReason(tmp: URL, expectedDurationSec: Double?, finished: Bool) -> String {
        guard finished else {
            return "the ffmpeg post-process timed out; capture intermediates were kept for recovery"
        }
        if let expected = expectedDurationSec, let produced = audioDurationSec(of: tmp),
           produced + durationToleranceSec < expected {
            return String(
                format: "the merged output was %.2fs against %.2fs of capture, so it was refused; capture intermediates were kept for recovery (REC9)",
                produced, expected
            )
        }
        return "ffmpeg post-process failed; capture intermediates were kept for recovery"
    }

    /// The `<stem>.merging.wav` temp ffmpeg writes to before promotion (REC7), so a
    /// truncated write never lands at the canonical `<stem>.wav`.
    static func mergingTempURL(forFinal final: URL) -> URL {
        final.deletingPathExtension().appendingPathExtension("merging.wav")
    }

    /// Atomically promote a verified temp WAV onto the canonical `final` path (REC7).
    /// Returns false (leaving `final` untouched) when the temp is implausible or the
    /// rename fails, so the caller keeps the intermediates for the orphan sweep.
    ///
    /// The one place a merge is refused for its length (REC9), so the event fires
    /// exactly once per post-process rather than once per plausibility read.
    private static func promoteMerged(tmp: URL, to final: URL, expectedDurationSec: Double?) -> Bool {
        guard producedPlausibleOutput(at: tmp, expectedDurationSec: expectedDurationSec) else {
            if let expected = expectedDurationSec, fileSize(tmp) > 4096 {
                let produced = audioDurationSec(of: tmp)
                Log.event(category: "recorder", action: "merge_too_short", attributes: [
                    "file": final.lastPathComponent,
                    "produced_sec": produced as Any,
                    "expected_sec": expected,
                ])
                Log.writeLine(
                    "recorder",
                    String(
                        format: "ERROR: %@ is %.2fs against %.2fs of capture; refusing to promote it and keeping the intermediates (REC9)",
                        tmp.lastPathComponent, produced ?? -1, expected
                    )
                )
            }
            return false
        }
        try? FileManager.default.removeItem(at: final)
        do {
            try FileManager.default.moveItem(at: tmp, to: final)
        } catch {
            Log.writeLine("recorder", "ERROR: could not promote \(tmp.lastPathComponent) to \(final.lastPathComponent): \(error.localizedDescription)")
            return false
        }
        return producedPlausibleOutput(at: final, expectedDurationSec: expectedDurationSec)
    }

    /// Merge mic + system into a 16 kHz stereo WAV (mic left, system right) written
    /// to `tmp`. Channel separation keeps diarization simple (per-channel RMS
    /// labelling) and makes a missing system channel obvious, instead of the old
    /// mono amix where a silent-system failure looked like "user was the only one
    /// talking" (the May 5 18:30 loss). ffmpeg-only: the absent-ffmpeg fallback is
    /// the caller's concern (its file retention differs). Never touches the final.
    ///
    /// `lengths` is the REC9 length policy: `apad` so neither leg can end the merge
    /// early, `adelay` so a late-starting system channel lands at the offset it was
    /// captured at, and `-t` at the target. Without it `amerge` ends with the
    /// shorter input, which is the truncation this whole path exists to prevent.
    private static func mergeToTempViaFFmpeg(mic: URL, system: URL, tmp: URL, lengths: MergeLengths) async -> Bool {
        guard let ffmpeg = findFFmpeg() else { return false }
        // Resample mic and system to 16 kHz mono, then amerge into stereo
        // (input 0 -> L, input 1 -> R).
        var systemChain = "aresample=16000,pan=mono|c0=0.5*c0+0.5*c1"
        if lengths.systemDelayMs > 0 {
            systemChain += ",adelay=\(lengths.systemDelayMs):all=1"
        }
        // The system leg is padded in BOTH shapes: when the mic is padded too the
        // `-t` below decides the length, and when it is not, the merge deliberately
        // ends with the mic.
        systemChain += ",apad"
        let micChain = "aresample=16000,aformat=channel_layouts=mono" + (lengths.padMic ? ",apad" : "")
        let filter = """
        [0:a]\(micChain)[micL];\
        [1:a]\(systemChain)[sysR];\
        [micL][sysR]amerge=inputs=2[stereo]
        """
        var args = [
            "-y", "-hide_banner", "-loglevel", "warning",
            "-i", mic.path,
            "-i", system.path,
            "-filter_complex", filter,
            "-map", "[stereo]",
        ]
        if let target = lengths.targetDurationSec {
            args += ["-t", String(format: "%.3f", target)]
        }
        args += [
            "-ar", "16000",
            "-c:a", "pcm_s16le",
            tmp.path,
        ]
        Log.writeLine(
            "recorder",
            String(
                format: "merge length policy: system_delay=%.2fs pad_mic=%@ target=%@",
                lengths.systemDelaySec,
                lengths.padMic ? "yes" : "no",
                lengths.targetDurationSec.map { String(format: "%.2fs", $0) } ?? "(mic length)"
            )
        )
        let ok = await runFFmpeg(ffmpeg: ffmpeg, args: args, label: "merge")
        return ok && producedPlausibleOutput(at: tmp, expectedDurationSec: lengths.expectedDurationSec)
    }

    /// Convert a single-source recording to 16 kHz mono Int16 written to `tmp`.
    /// Used when one capture side is missing. ffmpeg-absent copies the source
    /// as-is (the ASR stack resamples internally).
    private static func convertToTempViaFFmpeg(input: URL, tmp: URL, expectedDurationSec: Double?) async -> Bool {
        guard let ffmpeg = findFFmpeg() else {
            try? FileManager.default.copyItem(at: input, to: tmp)
            return producedPlausibleOutput(at: tmp, expectedDurationSec: expectedDurationSec)
        }
        let args = [
            "-y", "-hide_banner", "-loglevel", "warning",
            "-i", input.path,
            "-ac", "1", "-ar", "16000",
            "-c:a", "pcm_s16le",
            tmp.path,
        ]
        let ok = await runFFmpeg(ffmpeg: ffmpeg, args: args, label: "convert")
        return ok && producedPlausibleOutput(at: tmp, expectedDurationSec: expectedDurationSec)
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
