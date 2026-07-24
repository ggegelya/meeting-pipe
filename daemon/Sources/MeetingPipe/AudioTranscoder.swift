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
    static func compressToFLAC(wav: URL) throws -> URL {
        guard let ffmpeg = RecordingPostProcessor.findFFmpeg() else {
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
        let status = runFFmpeg(ffmpeg: ffmpeg, args: [
            "-y", "-hide_banner", "-loglevel", "warning",
            "-i", wav.path,
            "-c:a", "flac",
            "-compression_level", "8",
            "-f", "flac",
            temp.path,
        ])
        guard status == 0 else {
            try? fm.removeItem(at: temp)
            throw TranscodeError.ffmpegFailed(status)
        }
        guard fm.fileExists(atPath: temp.path) else {
            throw TranscodeError.outputMissing
        }

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

    private static func runFFmpeg(ffmpeg: String, args: [String]) -> Int32 {
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
            Log.writeLine("daemon", "ERROR ffmpeg flac launch: \(error.localizedDescription)")
            return -1
        }
        // Drain stderr before waiting: ffmpeg on a long recording can fill the pipe
        // buffer and deadlock against `waitUntilExit`.
        let stderr = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let tail = String(data: stderr, encoding: .utf8)?
                .split(separator: "\n").suffix(5).joined(separator: " | ") ?? ""
            Log.writeLine("daemon", "ffmpeg flac exit=\(proc.terminationStatus) tail=\(tail)")
        }
        return proc.terminationStatus
    }
}
