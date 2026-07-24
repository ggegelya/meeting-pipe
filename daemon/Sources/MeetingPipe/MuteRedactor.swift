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

    /// Mean mic level (dBFS) at or below which a muted span is judged genuinely
    /// quiet and safe to redact; above it the span carries speech, so the mute
    /// oracle was wrong for that span and it is withheld rather than zeroed (never
    /// destroy real speech, TECH-MIC9/MIC12). -50 dBFS sits well above room tone /
    /// digital silence (about -90) and below normal speech (about -25), so even a
    /// few seconds of speech inside a muted span clears it.
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

    /// Apply the at-rest protections every kept original must carry (ADR 0016):
    /// owner-only `0600` and exclusion from Time Machine / iCloud. Both write
    /// sites that land a full recording in `originals/` (this redactor's
    /// move-aside and the orphan quarantine) funnel through here so neither can
    /// silently drift from the ADR's requirement. That drift is exactly how the
    /// quarantine path shipped without backup exclusion (AUD-19).
    static func protectOriginalAtRest(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
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
        // Per-span runaway guard (TECH-MIC12, replacing the whole-file 85%-coverage
        // cliff of TECH-MIC9). A mute oracle that goes confidently-wrong (e.g.
        // Teams' new mini window detaches the cached AX element and a stale "muted"
        // is read) marks spans muted that actually carry the user's speech;
        // zeroing those would silently delete real speech from the consumed
        // artifact. So measure the mic energy WITHIN each muted span and redact
        // only the genuinely-quiet ones; a span carrying speech is where the oracle
        // was wrong, so it is withheld (kept) rather than zeroed. The old whole-file
        // guard withheld the ENTIRE redaction the moment any speech appeared (so a
        // mostly-muted all-hands kept its muted listening un-redacted) and redacted
        // timelines under 85% coverage unchecked; per-span analysis fixes both.
        // MIC14: a manual off-record span is explicit user intent, so it is always redacted and
        // exempt from the MIC12 speech-bearing withhold (which exists only to guard against a wrong
        // AUTO mute oracle). Split by source: manual spans redact unconditionally; auto (`.mute`)
        // spans keep the per-span speech guard below.
        let manualSpans = timeline.spans.filter { $0.source == .manual }
        let autoSpans = timeline.spans.filter { $0.source == .mute }
        let (autoRedact, withheldSpans) = partitionSpans(wav: wav, spans: autoSpans)
        let redactSpans = manualSpans + autoRedact
        if !withheldSpans.isEmpty {
            Log.event(category: "recorder", action: "mute_redaction_withheld", attributes: [
                "file": wav.lastPathComponent,
                "muted_spans": timeline.spans.count,
                "withheld_spans": withheldSpans.count,
                "redacted_spans": redactSpans.count,
                "reason": "speech_in_muted_span",
            ])
            Log.writeLine("recorder", "withheld \(withheldSpans.count)/\(timeline.spans.count) muted span(s) carrying speech for \(wav.lastPathComponent); redacting \(redactSpans.count) quiet span(s) (TECH-MIC12)")
        }
        guard !redactSpans.isEmpty else {
            // Every muted span carries speech: nothing is safe to redact. Keep the
            // full mic and reap the timeline so a re-run no-ops (the all-withhold
            // case the whole-file guard used to handle for a stuck oracle).
            Log.writeLine("recorder", "no muted span was quiet enough to redact for \(wav.lastPathComponent); kept the full mic recording (TECH-MIC12)")
            try? FileManager.default.removeItem(at: MuteTimelineFile.url(forFinal: wav))
            return false
        }
        let channels = channelCount(of: wav) ?? 2
        guard let filter = buildFilter(spans: redactSpans, channels: channels) else { return false }
        guard let ffmpeg = RecordingPostProcessor.findFFmpeg() else {
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
            protectOriginalAtRest(dest)
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

    /// Partition muted spans into those safe to redact (the mic is genuinely
    /// quiet within the span) and those withheld because the span carries speech
    /// (the oracle was wrong for that span; never destroy real speech,
    /// TECH-MIC9/MIC12). A span whose energy cannot be read is treated as suspect
    /// and withheld, so an unreadable region fails safe (keeps the audio).
    static func partitionSpans(
        wav: URL, spans: [MuteTimeline.Span]
    ) -> (redact: [MuteTimeline.Span], withheld: [MuteTimeline.Span]) {
        var redact: [MuteTimeline.Span] = []
        var withheld: [MuteTimeline.Span] = []
        for span in spans {
            if let db = micChannelMeanDb(of: wav, in: span), db <= speechFloorDb {
                redact.append(span)
            } else {
                withheld.append(span)
            }
        }
        return (redact, withheld)
    }

    /// Mean level (dBFS) of the mic channel (channel 0 = left) within `range`, or
    /// the whole file when `range` is nil. Reads in chunks so a long recording
    /// never loads whole, seeking to the range start and bounding the read to the
    /// range length. Returns nil if unreadable or the range has no frames. Runs
    /// offline (not the render thread).
    private static func micChannelMeanDb(of wav: URL, in range: MuteTimeline.Span? = nil) -> Float? {
        guard let file = try? AVAudioFile(forReading: wav) else { return nil }
        let format = file.processingFormat
        let rate = format.sampleRate
        guard format.channelCount >= 1, rate > 0 else { return nil }
        var remaining = file.length
        if let range = range {
            let start = AVAudioFramePosition(max(0, range.startSec) * rate)
            let end = AVAudioFramePosition(max(range.startSec, range.endSec) * rate)
            guard start < file.length else { return nil }
            file.framePosition = start
            remaining = min(end, file.length) - start
        }
        guard remaining > 0 else { return nil }
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }
        var sumSquares = 0.0
        var frames = 0.0
        while remaining > 0 {
            let toRead = AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining))
            do { try file.read(into: buffer, frameCount: toRead) } catch { return nil }
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
            remaining -= AVAudioFramePosition(count)
            if count < Int(toRead) { break }
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
                // SEC14: ffmpeg needs none of the managed API tokens; don't leak them to the child.
                proc.environment = Secrets.scrubbedEnvironment()
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
