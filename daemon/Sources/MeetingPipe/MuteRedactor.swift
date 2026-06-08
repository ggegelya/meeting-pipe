import AVFoundation
import Foundation

/// Offline mute-redaction (TECH-MIC5, ADR 0016). Under capture-first the mic is
/// recorded losslessly and the muted spans are logged to `<stem>.mute-timeline.json`
/// (TECH-MIC4). Before any consumer runs (the daemon's FluidAudio transcription
/// and the Python pipeline), this rewrites the canonical `<stem>.wav` with those
/// spans zero-filled on the mic channel, and keeps the full recording aside for
/// recovery.
///
/// The redaction is a `volume=0` over the muted time ranges, so frames are never
/// removed and the ADR 0009 L/R frame parity holds. The kept full recording goes
/// to a separate, non-enumerated directory (Application Support, not the
/// Library-scanned `raw/` tree and not the Raw Files tab), excluded from Time
/// Machine. Offline and recoverable: a wrong timeline mis-redacts rather than
/// destroys, and the full original is always restorable.
enum MuteRedactor {

    /// Redaction that would zero at least this fraction of the recording's mic
    /// channel is treated as a runaway oracle, not a real mute pattern, and is
    /// withheld when the mic carries speech (TECH-MIC9). A normal meeting mutes in
    /// bursts; a whole-recording mute is the stuck/confidently-wrong-oracle
    /// signature (the Teams mini-window incident redacted ~100%).
    static let runawayMutedFraction = 0.85

    /// Mean mic level (dBFS) above which a "muted" region is judged to carry real
    /// speech, so redacting it would destroy audio. -50 dBFS sits well above room
    /// tone / digital silence (about -90) and below normal speech (about -25), so
    /// even a few seconds of speech inside a long muted region clears it.
    static let speechFloorDb: Float = -50

    /// Directory for kept full recordings: app-private, outside the recordings
    /// (`raw/`) tree the Library and Raw Files tab enumerate, and outside the
    /// iCloud-synced Documents folder. So the sensitive full audio is local-only
    /// while the redacted artifact is what is scanned, played, and published.
    static func originalsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MeetingPipe/originals", isDirectory: true)
    }

    /// Kept-recording path for a final recording URL within `dir` (defaults to
    /// the app-private originals directory).
    static func originalsURL(for wav: URL, in dir: URL? = nil) -> URL {
        (dir ?? originalsDirectory()).appendingPathComponent(wav.lastPathComponent)
    }

    /// Build the `-filter_complex` that zeroes the mic channel over the muted
    /// spans. Stereo (mic L, system R) splits, zeroes L, and re-merges so system
    /// audio is untouched; mono zeroes the single channel. Returns nil when there
    /// is nothing to redact.
    static func buildFilter(spans: [MuteTimeline.Span], channels: Int) -> String? {
        guard !spans.isEmpty else { return nil }
        // `volume=0` is bypassed when `enable` is false and applied (silence)
        // when true; summing `between(t,...)` terms makes enable true inside any
        // muted span. Frame count is preserved (no frames dropped), so L/R parity
        // holds (ADR 0009).
        let enable = spans
            .map { "between(t,\(format($0.startSec)),\(format($0.endSec)))" }
            .joined(separator: "+")
        if channels >= 2 {
            return "[0:a]channelsplit=channel_layout=stereo[L][R];"
                + "[L]volume=0:enable='\(enable)'[Lm];"
                + "[Lm][R]amerge=inputs=2[out]"
        }
        return "[0:a]volume=0:enable='\(enable)'[out]"
    }

    /// Redact `wav` in place if a non-empty mute timeline exists for it. Moves the
    /// full recording to the originals directory and replaces `wav` with the
    /// redacted artifact. No-op (returns false) when there is no timeline (a
    /// regulated/NDA recording, an orphan recovered without a stop, or a
    /// pre-MIC4 file) or nothing was muted. On any failure the full `wav` is left
    /// intact (recoverable, never destroyed) and false is returned.
    @discardableResult
    static func redactIfNeeded(wav: URL, originalsDir: URL? = nil) async -> Bool {
        guard let timeline = MuteTimelineFile.read(forFinal: wav), !timeline.spans.isEmpty else {
            return false
        }
        let dir = originalsDir ?? originalsDirectory()
        guard FileManager.default.fileExists(atPath: wav.path) else { return false }
        // Idempotency (TECH-MIC5 review): if the full original was already moved
        // aside by a prior pass, this WAV is the redacted artifact already. A
        // re-run (reprocess / retry) must NOT move the redacted file over the
        // kept original, or the full recording is lost. Reap the stale timeline
        // and no-op.
        if FileManager.default.fileExists(atPath: originalsURL(for: wav, in: dir).path) {
            try? FileManager.default.removeItem(at: MuteTimelineFile.url(forFinal: wav))
            return false
        }
        // Audio-grounded runaway guard (TECH-MIC9). A mute oracle that goes
        // confidently-wrong (e.g. Teams' new mini window detaches the cached AX
        // element and a stale "muted" is read for the whole call) produces a
        // timeline that covers essentially the entire recording. Redacting it
        // would zero the whole mic channel and silently delete real speech from
        // the consumed artifact (the failure that motivated this guard). The full
        // recording is kept aside and is recoverable, but the loss is invisible
        // until someone checks. So when the timeline would redact almost the
        // whole recording AND the mic actually carries sustained energy, the
        // oracle is not trustworthy: withhold redaction, keep the full mic as the
        // canonical artifact, flag it, and reap the bogus timeline. A genuinely
        // all-muted-silent meeting (mic near digital silence) is redacted as
        // normal, because nothing real is lost.
        if let reason = runawayWithholdReason(wav: wav, spans: timeline.spans) {
            Log.event(category: "recorder", action: "mute_redaction_withheld", attributes: [
                "file": wav.lastPathComponent,
                "muted_spans": timeline.spans.count,
                "reason": reason,
            ])
            Log.writeLine("recorder", "withheld mute redaction for \(wav.lastPathComponent): \(reason); kept the full mic recording (TECH-MIC9)")
            try? FileManager.default.removeItem(at: MuteTimelineFile.url(forFinal: wav))
            return false
        }
        let channels = channelCount(of: wav) ?? 2
        guard let filter = buildFilter(spans: timeline.spans, channels: channels) else { return false }
        guard let ffmpeg = MeetingRecorder.findFFmpeg() else {
            Log.writeLine("recorder", "WARN: ffmpeg not found - skipping mute redaction for \(wav.lastPathComponent)")
            return false
        }

        let temp = wav.deletingPathExtension().appendingPathExtension("redacting.wav")
        try? FileManager.default.removeItem(at: temp)
        let args = [
            "-y", "-hide_banner", "-loglevel", "warning",
            "-i", wav.path,
            "-filter_complex", filter,
            "-map", "[out]",
            "-ar", "16000",
            "-c:a", "pcm_s16le",
            temp.path,
        ]
        let ok = await runFFmpeg(ffmpeg: ffmpeg, args: args)
        guard ok, FileManager.default.fileExists(atPath: temp.path) else {
            try? FileManager.default.removeItem(at: temp)
            Log.event(category: "recorder", action: "mute_redaction_failed", attributes: [
                "file": wav.lastPathComponent,
                "muted_spans": timeline.spans.count,
            ])
            return false
        }

        // Move the full recording aside for recovery, then promote the redacted
        // artifact to the canonical path consumers read. If the move-aside fails,
        // leave the full recording in place rather than risk losing it.
        guard moveOriginalAside(wav: wav, to: dir) else {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
        do {
            try FileManager.default.moveItem(at: temp, to: wav)
        } catch {
            // Redacted promote failed: restore the full recording so nothing is lost.
            try? FileManager.default.moveItem(at: originalsURL(for: wav, in: dir), to: wav)
            try? FileManager.default.removeItem(at: temp)
            Log.writeLine("recorder", "WARN: could not promote redacted artifact for \(wav.lastPathComponent), restored full recording")
            return false
        }

        // Reap the timeline so a re-run no-ops at the read guard above; the kept
        // original is the recovery source from here on (TECH-MIC5 review).
        try? FileManager.default.removeItem(at: MuteTimelineFile.url(forFinal: wav))

        Log.event(category: "recorder", action: "mute_redacted", attributes: [
            "file": wav.lastPathComponent,
            "muted_spans": timeline.spans.count,
            "channels": channels,
        ])
        return true
    }

    // MARK: - Private

    /// Move `wav` to the originals directory, 0600 and Time-Machine-excluded.
    private static func moveOriginalAside(wav: URL, to dir: URL) -> Bool {
        let dest = originalsURL(for: wav, in: dir)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: wav, to: dest)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDest = dest
            try? mutableDest.setResourceValues(values)
            return true
        } catch {
            Log.writeLine("recorder", "WARN: could not move full recording aside for \(wav.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    private static func channelCount(of wav: URL) -> Int? {
        guard let file = try? AVAudioFile(forReading: wav) else { return nil }
        return Int(file.fileFormat.channelCount)
    }

    /// Reason to withhold redaction, or nil to proceed. Withheld when the muted
    /// spans cover at least `runawayMutedFraction` of the recording AND the mic
    /// (left/channel-0) carries sustained energy above `speechFloorDb`. Both must
    /// hold: a runaway timeline over a silent mic is harmless to redact, and a
    /// localized mute over a loud mic is a genuine muted aside the opt-in user
    /// asked to remove (TECH-MIC9).
    static func runawayWithholdReason(wav: URL, spans: [MuteTimeline.Span]) -> String? {
        guard let duration = durationSeconds(of: wav), duration > 0 else { return nil }
        let mutedSeconds = spans.reduce(0.0) { $0 + max(0, $1.endSec - $1.startSec) }
        guard mutedSeconds / duration >= runawayMutedFraction else { return nil }
        guard let micDb = micChannelMeanDb(of: wav), micDb > speechFloorDb else { return nil }
        return "runaway_muted_span_over_live_mic"
    }

    private static func durationSeconds(of wav: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: wav) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return nil }
        return Double(file.length) / rate
    }

    /// Mean level (dBFS) of the mic channel (channel 0 = left), read in chunks so
    /// a long recording never loads whole. Runs offline (not the render thread).
    private static func micChannelMeanDb(of wav: URL) -> Float? {
        guard let file = try? AVAudioFile(forReading: wav) else { return nil }
        let format = file.processingFormat
        guard format.channelCount >= 1 else { return nil }
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }
        var sumSquares = 0.0
        var frames = 0.0
        while true {
            do { try file.read(into: buffer, frameCount: chunk) } catch { return nil }
            let count = Int(buffer.frameLength)
            if count == 0 { break }
            guard let mic = buffer.floatChannelData?[0] else { return nil }
            var local = 0.0
            for i in 0..<count {
                let v = Double(mic[i])
                local += v * v
            }
            sumSquares += local
            frames += Double(count)
            if count < Int(chunk) { break }
        }
        guard frames > 0 else { return nil }
        let meanSquare = sumSquares / frames
        return meanSquare > 0 ? Float(10.0 * log10(meanSquare)) : -120
    }

    /// Trim to millisecond precision; ffmpeg `between` wants plain decimals.
    private static func format(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }

    private static func runFFmpeg(ffmpeg: String, args: [String]) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: ffmpeg)
                proc.arguments = args
                let errPipe = Pipe()
                proc.standardError = errPipe
                proc.standardOutput = FileHandle.nullDevice
                do {
                    try proc.run()
                } catch {
                    Log.writeLine("recorder", "ERROR ffmpeg redact launch: \(error.localizedDescription)")
                    continuation.resume(returning: false)
                    return
                }
                proc.waitUntilExit()
                if proc.terminationStatus != 0 {
                    let stderr = errPipe.fileHandleForReading.availableData
                    let tail = String(data: stderr, encoding: .utf8)?
                        .split(separator: "\n").suffix(5).joined(separator: " | ") ?? ""
                    Log.writeLine("recorder", "ffmpeg redact exit=\(proc.terminationStatus) tail=\(tail)")
                }
                continuation.resume(returning: proc.terminationStatus == 0)
            }
        }
    }
}
