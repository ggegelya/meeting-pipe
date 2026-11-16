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

    /// What `redactIfNeeded` did (SEC16). It used to answer a bare `Bool`, the same `false` for
    /// "nothing to cut" and for every failure, and its one caller discarded it, so a missing
    /// ffmpeg or a corrupt timeline transcribed and published the uncut recording. `.failed` is
    /// the caller's cue to hold the meeting back instead.
    enum Outcome: Equatable {
        /// No timeline and no evidence one was owed, nothing muted, or every auto span withheld
        /// by the MIC12 speech guard: the WAV is safe to consume as it is.
        case notNeeded
        /// The canonical WAV is now the redacted artifact (this pass or an earlier one).
        case redacted
        /// Redaction was owed and did not happen; the WAV on disk may hold the uncut audio.
        case failed(FailureReason)
    }

    /// Why a redaction that was owed did not happen. The raw value is the `reason` attribute of
    /// `mute_redaction_failed` and the token in the held-back row's failure sidecar.
    enum FailureReason: String, Equatable, CaseIterable {
        /// A `<stem>.mute-timeline.json` exists but does not decode.
        case timelineUnreadable = "timeline_unreadable"
        /// No timeline, but a start-time marker says one was owed: the MIC14 `.offrecord` marker,
        /// or a `.capturemode` marker for a redaction-opt-in recording (both kept until the
        /// timeline write lands).
        case timelineMissing = "timeline_missing"
        case ffmpegMissing = "ffmpeg_missing"
        case ffmpegFailed = "ffmpeg_failed"
        case moveAsideFailed = "move_aside_failed"
        case promoteFailed = "promote_failed"
        /// The final recording cannot be opened at all, so no span can be measured and no cut can
        /// be made. It used to read as every span "carrying speech" and fall through to an
        /// uncut transcription of the same unreadable file (SEC26).
        case audioUnreadable = "audio_unreadable"
    }

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

    /// Where a recording that must not be consumed AND has no redacted twin lands (SEC26): a
    /// held-back meeting (SEC16) or a quarantined orphan. A subfolder of `originals/` that
    /// `OriginalsReaper` never enters, because the reaper deletes by age and size and this is the
    /// only copy there is. Only the owner removes what is in it.
    static func heldDirectory(in originals: URL? = nil) -> URL {
        (originals ?? originalsDirectory()).appendingPathComponent("held", isDirectory: true)
    }

    /// The held recording for a stem, if one is there: `<stem>.wav`, or the uniquified name a second
    /// hold of the same stem gets (`<stem>.held-<n>.wav`).
    static func heldRecording(stem: String, in originals: URL? = nil) -> URL? {
        heldRecordings(stem: stem, in: originals).first
    }

    /// Every held recording for a stem: the plain one first, then the uniquified ones in numeric order.
    static func heldRecordings(stem: String, in originals: URL? = nil) -> [URL] {
        let dir = heldDirectory(in: originals)
        var out: [URL] = []
        let plain = dir.appendingPathComponent("\(stem).wav")
        if FileManager.default.fileExists(atPath: plain.path) { out.append(plain) }
        let prefix = "\(stem).held-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let numbered = names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix(prefix), name.hasSuffix(".wav"),
                  let n = Int(name.dropFirst(prefix.count).dropLast(4)) else { return nil }
            return (n, name)
        }.sorted { $0.0 < $1.0 }
        out += numbered.map { dir.appendingPathComponent($0.1) }
        return out
    }

    /// One at-rest protection that did not apply.
    struct ProtectionFailure: Equatable {
        /// `permissions` (0600) or `backup_exclusion` (Time Machine / iCloud).
        let protection: String
        let errorDomain: String
        let errorCode: Int
    }

    /// Apply the at-rest protections every kept original must carry (ADR 0016):
    /// owner-only `0600` and exclusion from Time Machine / iCloud. Both write
    /// sites that land a full recording in `originals/` (this redactor's
    /// move-aside and the orphan quarantine) funnel through here so neither can
    /// silently drift from the ADR's requirement. That drift is exactly how the
    /// quarantine path shipped without backup exclusion (AUD-19).
    ///
    /// SEC26: each protection's result is checked and a failure is logged (`recorder.log` WARN and an
    /// `at_rest_protection_failed` event) and returned, instead of vanishing behind `try?`. The caller
    /// still completes its move: refusing it would leave the full recording in `raw/`, the iCloud-synced
    /// tree on the owner's Mac, which is strictly worse than an unprotected copy outside it.
    @discardableResult
    static func protectOriginalAtRest(_ url: URL) -> [ProtectionFailure] {
        var failures: [ProtectionFailure] = []
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            failures.append(failure("permissions", error))
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        do {
            try mutable.setResourceValues(values)
        } catch {
            failures.append(failure("backup_exclusion", error))
        }
        reportProtectionFailures(failures, file: url)
        return failures
    }

    private static func failure(_ protection: String, _ error: Error) -> ProtectionFailure {
        let ns = error as NSError
        return ProtectionFailure(protection: protection, errorDomain: ns.domain, errorCode: ns.code)
    }

    /// Log protections that did not apply to `file`. Shared with the transcript's `0600` write.
    static func reportProtectionFailures(_ failures: [ProtectionFailure], file: URL) {
        for f in failures {
            Log.writeLine("recorder", "WARN: could not apply \(f.protection) to \(file.lastPathComponent) (\(f.errorDomain) \(f.errorCode))")
            Log.event(category: "recorder", action: "at_rest_protection_failed", attributes: [
                "file": file.lastPathComponent,
                "protection": f.protection,
                "error_domain": f.errorDomain,
                "error_code": f.errorCode,
            ])
        }
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
    /// redacted artifact. `.notNeeded` when there is no timeline and nothing on disk
    /// says one was owed (a regulated/NDA recording, a default capture-first
    /// recording with no off-the-record span, or a pre-MIC4 file), or nothing was
    /// muted. Every other way of not redacting is `.failed` (SEC16), and the full
    /// `wav` is left intact (recoverable, never destroyed).
    ///
    /// `redactionOwed` is the job's own record that a cut was owed (REC21): the session sets it
    /// for a redact-opt-in recording or once an off-the-record span opened under lossless capture,
    /// so a clean stop whose marker writes both failed still fails closed here.
    static func redactIfNeeded(
        wav: URL,
        redactionOwed: Bool = false,
        originalsDir: URL? = nil,
        findFFmpeg: () -> String? = RecordingPostProcessor.findFFmpeg,
        ceilingSeconds: Double? = nil,
        move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) async -> Outcome {
        let timeline: MuteTimelineFile
        switch MuteTimelineFile.load(forFinal: wav) {
        case .loaded(let file):
            timeline = file
        case .unreadable:
            return fail(.timelineUnreadable, wav: wav, mutedSpans: nil)
        case .missing:
            // SEC16: a failed timeline write used to read exactly like "no timeline", and the
            // markers that said otherwise were already gone. Both now survive until a timeline
            // lands (the recorder keeps `.capturemode`, the job removes `.offrecord` only after
            // this returns), so either one here means the spans were lost.
            // REC21: the job's own `redactionOwed` counts too, and a `.capturemode` that exists but
            // cannot be read is owed, not absent.
            if redactionOwed
                || OffRecordMarker.exists(forFinal: wav)
                || CaptureMode.readMarker(forFinal: wav).owesRedaction {
                // SEC26: unless a pass that finished after its job's deadline already did the cut: the
                // timeline is reaped and the full recording is aside, so this WAV is the redacted
                // artifact. Holding it back would hold the redacted file and leave the real original
                // in the reaped top level.
                let aside = originalsURL(for: wav, in: originalsDir ?? originalsDirectory())
                if FileManager.default.fileExists(atPath: aside.path),
                   !FileManager.default.contentsEqual(atPath: aside.path, andPath: wav.path) {
                    return .redacted
                }
                return fail(.timelineMissing, wav: wav, mutedSpans: nil)
            }
            return .notNeeded
        }
        guard !timeline.spans.isEmpty else { return .notNeeded }
        let dir = originalsDir ?? originalsDirectory()
        guard FileManager.default.fileExists(atPath: wav.path) else { return .notNeeded }
        // Idempotency (TECH-MIC5 review): if the full original was already moved
        // aside by a prior pass, this WAV is the redacted artifact already. A
        // re-run (reprocess / retry) must NOT move the redacted file over the
        // kept original, or the full recording is lost. Reap the stale timeline
        // and no-op. SEC16: unless the two are byte-identical, which means this WAV
        // is the full recording itself, copied back by hand from a held-back
        // meeting (that quarantine lands in this same directory), so it is
        // redacted like any other.
        let kept = originalsURL(for: wav, in: dir)
        if FileManager.default.fileExists(atPath: kept.path),
           !FileManager.default.contentsEqual(atPath: kept.path, andPath: wav.path) {
            try? FileManager.default.removeItem(at: MuteTimelineFile.url(forFinal: wav))
            return .redacted
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
        // SEC26: a final that cannot be opened at all is its own failure. Every span would otherwise
        // read as unmeasurable and be withheld, the timeline reaped, and the full audio sent on to a
        // transcription that fails on the same file. The timeline stays where it is for a later pass.
        // Only when an auto span has to be measured: a manual span is cut by ffmpeg, which reads files
        // AVAudioFile cannot, and that meeting used to be cut rather than held.
        guard autoSpans.isEmpty || (try? AVAudioFile(forReading: wav)) != nil else {
            return fail(.audioUnreadable, wav: wav, mutedSpans: timeline.spans.count)
        }
        let partition = partitionSpans(wav: wav, spans: autoSpans)
        let autoRedact = partition.redact
        let withheldSpans = partition.withheld + partition.unmeasured
        let redactSpans = manualSpans + autoRedact
        if !withheldSpans.isEmpty {
            Log.event(category: "recorder", action: "mute_redaction_withheld", attributes: [
                "file": wav.lastPathComponent,
                "muted_spans": timeline.spans.count,
                "withheld_spans": withheldSpans.count,
                "redacted_spans": redactSpans.count,
                "speech_spans": partition.withheld.count,
                "unmeasured_spans": partition.unmeasured.count,
            ])
            Log.writeLine("recorder", "withheld \(withheldSpans.count)/\(timeline.spans.count) muted span(s) (\(partition.withheld.count) carrying speech, \(partition.unmeasured.count) that could not be measured) for \(wav.lastPathComponent); redacting \(redactSpans.count) quiet span(s) (TECH-MIC12)")
        }
        guard !redactSpans.isEmpty else {
            // Every muted span carries speech: nothing is safe to redact. Keep the
            // full mic and reap the timeline so a re-run no-ops (the all-withhold
            // case the whole-file guard used to handle for a stuck oracle).
            Log.writeLine("recorder", "no muted span was quiet enough to redact for \(wav.lastPathComponent); kept the full mic recording (TECH-MIC12)")
            try? FileManager.default.removeItem(at: MuteTimelineFile.url(forFinal: wav))
            return .notNeeded
        }
        let channels = channelCount(of: wav) ?? 2
        guard let filter = buildFilter(spans: redactSpans, channels: channels) else { return .notNeeded }
        guard let ffmpeg = findFFmpeg() else {
            return fail(.ffmpegMissing, wav: wav, mutedSpans: timeline.spans.count)
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
        // CONC5: this runs at the head of the serial lane, before the row has a live entry, so a wedged
        // ffmpeg used to hold every job behind it with no Cancel. Past the ceiling it is killed, and the
        // outcome is `.failed(.ffmpegFailed)` (SEC16 holds the meeting back), never `.notNeeded`.
        let ceiling = ceilingSeconds ?? redactionCeilingSeconds(forDurationSec: RecordingPostProcessor.audioDurationSec(of: wav))
        let run = await runFFmpeg(ffmpeg: ffmpeg, args: args, ceilingSeconds: ceiling)
        guard run.ok, FileManager.default.fileExists(atPath: temp.path) else {
            // Only after the child is reaped: one still writing would keep an unlinked file.
            if run.reaped { try? FileManager.default.removeItem(at: temp) }
            return fail(.ffmpegFailed, wav: wav, mutedSpans: timeline.spans.count)
        }

        // Move the full recording aside for recovery, then promote the redacted
        // artifact to the canonical path consumers read. If the move-aside fails,
        // leave the full recording in place rather than risk losing it.
        guard moveOriginalAside(wav: wav, to: dir) else {
            try? FileManager.default.removeItem(at: temp)
            return fail(.moveAsideFailed, wav: wav, mutedSpans: timeline.spans.count)
        }
        do {
            try move(temp, wav)
        } catch {
            // Redacted promote failed: restore the full recording so nothing is lost. SEC26: the restore
            // is checked. If it fails too, the only copy sits in `originals/`, where the reaper would
            // take it, so say so and let the held-back path move it into `held/`.
            let restored: Bool
            do {
                try move(originalsURL(for: wav, in: dir), wav)
                restored = true
            } catch {
                restored = false
            }
            try? FileManager.default.removeItem(at: temp)
            if restored {
                Log.writeLine("recorder", "WARN: could not promote redacted artifact for \(wav.lastPathComponent), restored full recording")
            } else {
                Log.writeLine("recorder", "ERROR: could not restore full recording for \(wav.lastPathComponent); it remains in originals")
                // Do not leave the only copy in the reaped top level while the job unwinds: the
                // reaper also runs after every job, and a job past its deadline never reaches the
                // dispatcher's hold.
                _ = try? quarantine(originalsURL(for: wav, in: dir), in: dir)
            }
            return fail(.promoteFailed, wav: wav, mutedSpans: timeline.spans.count, restored: restored)
        }

        // Reap the timeline so a re-run no-ops at the read guard above; the kept
        // original is the recovery source from here on (TECH-MIC5 review).
        try? FileManager.default.removeItem(at: MuteTimelineFile.url(forFinal: wav))

        Log.event(category: "recorder", action: "mute_redacted", attributes: [
            "file": wav.lastPathComponent,
            "muted_spans": timeline.spans.count,
            "channels": channels,
        ])
        return .redacted
    }

    /// Move a recording that must not be consumed out of the Library-scanned tree into
    /// `originals/held/`, with the at-rest protections. Shared by the orphan quarantine and the
    /// held-back job (SEC16) so the two moves cannot drift; each caller logs its own action.
    ///
    /// `dir` is the originals directory the `held/` folder sits under (tests inject one). A held
    /// file of the same name that is not byte-identical is never replaced: this recording is the only
    /// copy, and so is that one, so the newcomer takes a `<stem>.held-<n>.wav` name instead.
    static func quarantine(_ url: URL, in dir: URL? = nil) throws -> URL {
        let held = heldDirectory(in: dir)
        try FileManager.default.createDirectory(at: held, withIntermediateDirectories: true)
        var dest = held.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            if FileManager.default.contentsEqual(atPath: dest.path, andPath: url.path) {
                // Already held, byte for byte: keep the held file and drop the duplicate source, so a
                // failure part way never leaves the source (maybe the reapable copy) as the only one.
                try FileManager.default.removeItem(at: url)
                return dest
            } else {
                let stem = url.deletingPathExtension().lastPathComponent
                var n = 1
                repeat {
                    dest = held.appendingPathComponent("\(stem).held-\(n).\(url.pathExtension)")
                    n += 1
                } while FileManager.default.fileExists(atPath: dest.path)
            }
        }
        try FileManager.default.moveItem(at: url, to: dest)
        protectOriginalAtRest(dest)
        return dest
    }

    // MARK: - Private

    /// Log a failed redaction once, with its reason, and hand back the outcome (SEC16).
    private static func fail(_ reason: FailureReason, wav: URL, mutedSpans: Int?, restored: Bool? = nil) -> Outcome {
        var attributes: [String: Any] = [
            "file": wav.lastPathComponent,
            "reason": reason.rawValue,
        ]
        if let mutedSpans { attributes["muted_spans"] = mutedSpans }
        if let restored { attributes["restored"] = restored }
        Log.event(category: "recorder", action: "mute_redaction_failed", attributes: attributes)
        Log.writeLine("recorder", "ERROR: mute redaction failed (\(reason.rawValue)) for \(wav.lastPathComponent)")
        return .failed(reason)
    }

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
    /// quiet within the span), those withheld because the span carries speech
    /// (the oracle was wrong for that span; never destroy real speech,
    /// TECH-MIC9/MIC12), and those whose energy cannot be measured (a span past the end of the
    /// file, no frames, a failed read). An unmeasured span fails safe like a speech-bearing
    /// one and is kept, but is counted apart (SEC26): "carrying speech" is a claim about audio, and
    /// nothing was heard.
    static func partitionSpans(
        wav: URL, spans: [MuteTimeline.Span]
    ) -> (redact: [MuteTimeline.Span], withheld: [MuteTimeline.Span], unmeasured: [MuteTimeline.Span]) {
        var redact: [MuteTimeline.Span] = []
        var withheld: [MuteTimeline.Span] = []
        var unmeasured: [MuteTimeline.Span] = []
        for span in spans {
            guard let db = micChannelMeanDb(of: wav, in: span) else {
                unmeasured.append(span)
                continue
            }
            if db <= speechFloorDb { redact.append(span) } else { withheld.append(span) }
        }
        return (redact, withheld, unmeasured)
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

    /// A minute plus 5% of the recording's duration. The merge ffmpeg processed 2,116 s of audio in 1.9 s
    /// on 2026-10-16 (about 1100x realtime), so an hour-long cut has ~3 minutes to finish a job that
    /// takes seconds: generous against a loaded Mac, and finite against a wedge.
    static func redactionCeilingSeconds(forDurationSec duration: Double?) -> Double {
        60 + max(0, duration ?? 0) * 0.05
    }

    private static func runFFmpeg(ffmpeg: String, args: [String], ceilingSeconds: Double) async -> (ok: Bool, reaped: Bool) {
        // SEC14: ffmpeg needs none of the managed API tokens; don't leak them to the child.
        let result = await ProcessRunner.runAsync(
            executable: ffmpeg, arguments: args, environment: Secrets.scrubbedEnvironment(),
            timeout: ceilingSeconds, qos: .userInitiated
        )
        if let failure = result.launchFailure {
            Log.writeLine("recorder", "ERROR ffmpeg redact launch: \(failure)")
            return (false, true)
        }
        if result.timedOut || result.status != 0 {
            let tail = result.stderrText.split(separator: "\n").suffix(5).joined(separator: " | ")
            Log.writeLine("recorder", "ffmpeg redact exit=\(result.status) timed_out=\(result.timedOut) tail=\(tail)")
        }
        return (result.succeeded, result.reaped)
    }
}
