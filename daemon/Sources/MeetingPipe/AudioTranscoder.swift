import AVFoundation
import Foundation

/// WAV to FLAC transcode for STOR1's `compress` retention policy. Lossless, so
/// the compressed meeting stays a faithful archive and stays reprocessable: both
/// `AVAudioFile` (playback, waveform) and the pipeline's `soundfile` reads decode
/// FLAC natively.
///
/// Blocking `Process` work, same as `MuteRedactor`'s ffmpeg path. Off-main callers
/// only; the retention sweep already runs on a detached background task.
enum AudioTranscoder {

    enum TranscodeError: Error, Equatable {
        case ffmpegMissing
        case ffmpegFailed(Int32)
        /// ffmpeg ran past its ceiling and was killed (CONC5). The WAV is untouched.
        case timedOut
        case outputMissing
        /// The FLAC decoded to a materially different duration than the WAV. The
        /// WAV is kept and the FLAC discarded.
        case verificationFailed(wavSeconds: Double, flacSeconds: Double)
    }

    /// Tolerance when comparing the source and transcoded durations. FLAC is
    /// lossless and frame-exact, so this only absorbs sample-rate rounding at the
    /// last frame; anything larger means ffmpeg truncated the file and the WAV
    /// must survive.
    static let durationToleranceSec: Double = 0.05

    /// Transcode `wav` to a sibling `<stem>.flac`, verify the result, then delete
    /// the WAV. Returns the new FLAC URL.
    ///
    /// The ordering is the whole point: encode to a `.writing` temp, move it into
    /// place atomically, reopen and compare durations, and only then remove the
    /// source. Every failure path leaves the original WAV untouched, because the
    /// audio is irreplaceable and a half-transcoded meeting is worse than a large
    /// one.
    @discardableResult
    static func compressToFLAC(wav: URL, ffmpegPath: String? = nil, ceilingSeconds: Double? = nil) throws -> URL {
        guard let ffmpeg = ffmpegPath ?? RecordingPostProcessor.findFFmpeg() else {
            throw TranscodeError.ffmpegMissing
        }
        let fm = FileManager.default
        let flac = wav.deletingPathExtension().appendingPathExtension("flac")
        let temp = wav.deletingPathExtension().appendingPathExtension("flac.writing")
        try? fm.removeItem(at: temp)

        let sourceSeconds = try duration(of: wav)
        // `-compression_level 8` is ffmpeg's slow-but-small preset. The sweep is a
        // background chore on a settled meeting, so wall time is free and bytes
        // are the point.
        let run = runFFmpeg(ffmpeg: ffmpeg, ceilingSeconds: ceilingSeconds ?? flacCeilingSeconds(forDurationSec: sourceSeconds), args: [
            "-y", "-hide_banner", "-loglevel", "warning",
            "-i", wav.path,
            "-c:a", "flac",
            "-compression_level", "8",
            "-f", "flac",
            temp.path,
        ])
        guard run.status == 0, !run.timedOut else {
            // A killed child that could not be reaped may still be writing the temp: leave it for the
            // next encode's own stale-temp removal rather than unlink a file ffmpeg holds open.
            if run.reaped { try? fm.removeItem(at: temp) }
            throw run.timedOut ? TranscodeError.timedOut : TranscodeError.ffmpegFailed(run.status)
        }
        guard fm.fileExists(atPath: temp.path) else {
            throw TranscodeError.outputMissing
        }

        // SEC22: owner-only before it takes the WAV's place; ffmpeg wrote it at the umask.
        OwnerOnlyFiles.restrict(temp)
        try? fm.removeItem(at: flac)
        do {
            try fm.moveItem(at: temp, to: flac)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }

        let transcodedSeconds: Double
        do {
            transcodedSeconds = try duration(of: flac)
        } catch {
            try? fm.removeItem(at: flac)
            throw error
        }
        guard abs(transcodedSeconds - sourceSeconds) <= durationToleranceSec else {
            try? fm.removeItem(at: flac)
            throw TranscodeError.verificationFailed(
                wavSeconds: sourceSeconds, flacSeconds: transcodedSeconds
            )
        }

        try fm.removeItem(at: wav)
        return flac
    }

    /// Playable duration, read through the same decoder the Library plays with, so
    /// a file that verifies here is a file the app can open.
    static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return 0 }
        return Double(file.length) / rate
    }

    /// A minute plus 5% of the WAV's duration. Measured 2026-11-17: one `-compression_level 8` encode of an
    /// hour of 16 kHz stereo took 1.8 s with other builds running (about 2000x realtime), so an hour-long
    /// file has 240 s, over 100 times what it takes, and a wedge is still finite.
    static func flacCeilingSeconds(forDurationSec duration: Double) -> Double {
        60 + max(0, duration) * 0.05
    }

    private static func runFFmpeg(
        ffmpeg: String, ceilingSeconds: Double, args: [String]
    ) -> (status: Int32, timedOut: Bool, reaped: Bool) {
        // SEC14: ffmpeg needs none of the managed API tokens; don't leak them to the child.
        // CONC5: stderr drains while ffmpeg runs, and a run past the ceiling is killed.
        let result = ProcessRunner.run(
            executable: ffmpeg, arguments: args, environment: Secrets.scrubbedEnvironment(), timeout: ceilingSeconds
        )
        if let failure = result.launchFailure {
            Log.writeLine("daemon", "ERROR ffmpeg flac launch: \(failure)")
            return (-1, false, true)
        }
        if result.status != 0 || result.timedOut {
            let tail = result.stderrText.split(separator: "\n").suffix(5).joined(separator: " | ")
            Log.writeLine("daemon", "ffmpeg flac exit=\(result.status) timed_out=\(result.timedOut) tail=\(tail)")
        }
        return (result.status, result.timedOut || !result.reaped, result.reaped)
    }
}
