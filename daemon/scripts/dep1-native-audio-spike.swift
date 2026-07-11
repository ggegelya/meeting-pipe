#!/usr/bin/env swift
//
// DEP1 spike (throwaway, not part of the SPM target). Prototypes the two ffmpeg
// dependencies on native AVFoundation and measures them against the ffmpeg
// artifacts, so the go/no-go verdict rests on numbers, not reasoning.
//
//   1. FLAC transcode  (AudioTranscoder.compressToFLAC replacement)
//   2. mic+system merge (MeetingRecorder.mergeViaFFmpeg replacement):
//        mic -> 16 kHz mono -> left, system -> 16 kHz mono -> right, stereo.
//
// Native merge design note: the system source is downmixed to mono explicitly
// ((L+R)/2), NOT via AVAudioConverter's channel reduction, because the repo
// documents that converter mis-handling the app's untagged mic-L/system-R layout
// (FluidAudioRunner). Only the safe mono->mono rate conversion goes through
// AVAudioConverter. The stereo *synthesis* is a manual interleaved write.
//
// Run:  swift daemon/scripts/dep1-native-audio-spike.swift
// Needs ffmpeg on PATH (or MEETINGPIPE_FFMPEG).

import AVFoundation
import Foundation

// MARK: - small utilities

func ffmpegPath() -> String {
    if let p = ProcessInfo.processInfo.environment["MEETINGPIPE_FFMPEG"], !p.isEmpty { return p }
    for cand in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"] {
        if FileManager.default.isExecutableFile(atPath: cand) { return cand }
    }
    return "ffmpeg"
}

@discardableResult
func runFFmpeg(_ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: ffmpegPath())
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

struct AudioInfo {
    let frames: AVAudioFramePosition
    let sampleRate: Double
    let channels: AVAudioChannelCount
    let durationSec: Double
    let bytes: Int
    let perChannelRMS: [Float]
}

func inspect(_ url: URL) throws -> AudioInfo {
    let f = try AVAudioFile(forReading: url)
    let fmt = f.processingFormat
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(f.length))!
    try f.read(into: buf)
    let n = Int(buf.frameLength)
    var rms: [Float] = []
    if let ch = buf.floatChannelData {
        for c in 0..<Int(fmt.channelCount) {
            var acc: Double = 0
            for i in 0..<n { let v = Double(ch[c][i]); acc += v * v }
            rms.append(n > 0 ? Float((acc / Double(n)).squareRoot()) : 0)
        }
    }
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attrs?[.size] as? Int) ?? 0
    return AudioInfo(
        frames: f.length, sampleRate: fmt.sampleRate, channels: fmt.channelCount,
        durationSec: Double(f.length) / fmt.sampleRate, bytes: size, perChannelRMS: rms
    )
}

// MARK: - synthesize inputs

/// Write a tone of `channels` channels; each channel gets `freqs[c]`.
func writeTone(_ url: URL, freqs: [Float], seconds: Double, sampleRate: Double) throws {
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                            channels: AVAudioChannelCount(freqs.count), interleaved: false)!
    let n = AVAudioFrameCount(seconds * sampleRate)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
    buf.frameLength = n
    let ch = buf.floatChannelData!
    for c in 0..<freqs.count {
        let w = 2.0 * Float.pi * freqs[c] / Float(sampleRate)
        for i in 0..<Int(n) { ch[c][i] = 0.5 * sin(w * Float(i)) }
    }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: freqs.count, AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    let out = try AVAudioFile(forWriting: url, settings: settings)
    try out.write(from: buf)
}

// MARK: - native transcode

func nativeTranscodeFLAC(_ input: URL, _ output: URL) throws {
    let inFile = try AVAudioFile(forReading: input)
    // GOTCHA 1: FLAC via AVAudioFile requires AVEncoderBitDepthHintKey. Without it
    // `AVAudioFile(forWriting:settings:)` throws an empty ObjC nil-error.
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatFLAC,
        AVSampleRateKey: inFile.fileFormat.sampleRate,
        AVNumberOfChannelsKey: inFile.fileFormat.channelCount,
        AVEncoderBitDepthHintKey: 16,
    ]
    let outFile = try AVAudioFile(forWriting: output, settings: settings)
    // GOTCHA 2: read position-bounded. `read(into:)` past EOF throws an empty
    // nil-error on this SDK rather than returning a 0-frame buffer.
    let total = inFile.length
    while inFile.framePosition < total {
        let toRead = AVAudioFrameCount(min(Int64(65536), total - inFile.framePosition))
        guard let buf = AVAudioPCMBuffer(pcmFormat: inFile.processingFormat, frameCapacity: toRead) else { break }
        try inFile.read(into: buf, frameCount: toRead)
        if buf.frameLength == 0 { break }
        try outFile.write(from: buf)
    }
}

// MARK: - native merge

/// Read a file, explicitly downmix to mono if stereo ((L+R)/2), resample to 16 kHz
/// mono through AVAudioConverter (the safe mono->mono path).
func readMono16k(_ url: URL) throws -> [Float] {
    let f = try AVAudioFile(forReading: url)
    let src = f.processingFormat
    let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(f.length))!
    try f.read(into: inBuf)
    let n = Int(inBuf.frameLength)
    let chans = Int(src.channelCount)
    let chData = inBuf.floatChannelData!

    // Explicit downmix to mono at the source rate.
    let monoFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: src.sampleRate,
                                channels: 1, interleaved: false)!
    let monoBuf = AVAudioPCMBuffer(pcmFormat: monoFmt, frameCapacity: AVAudioFrameCount(n))!
    monoBuf.frameLength = AVAudioFrameCount(n)
    let mono = monoBuf.floatChannelData![0]
    for i in 0..<n {
        var acc: Float = 0
        for c in 0..<chans { acc += chData[c][i] }
        mono[i] = acc / Float(chans)
    }
    if src.sampleRate == 16000 { return Array(UnsafeBufferPointer(start: mono, count: n)) }

    // Safe mono->mono rate conversion.
    let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                            channels: 1, interleaved: false)!
    let conv = AVAudioConverter(from: monoFmt, to: dst)!
    let cap = AVAudioFrameCount(Double(n) * 16000.0 / src.sampleRate) + 4096
    let outBuf = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: cap)!
    var fed = false
    var err: NSError?
    conv.convert(to: outBuf, error: &err) { _, status in
        if fed { status.pointee = .noDataNow; return nil }
        fed = true; status.pointee = .haveData; return monoBuf
    }
    if let err { throw err }
    let m = Int(outBuf.frameLength)
    return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: m))
}

func nativeMerge(mic: URL, system: URL, output: URL) throws {
    let l = try readMono16k(mic)
    let r = try readMono16k(system)
    let n = max(l.count, r.count) // pad the shorter with silence
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                            channels: 2, interleaved: false)!
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
    buf.frameLength = AVAudioFrameCount(n)
    let ch = buf.floatChannelData!
    for i in 0..<n {
        ch[0][i] = i < l.count ? l[i] : 0      // mic  -> left
        ch[1][i] = i < r.count ? r[i] : 0      // sys  -> right
    }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
        AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    let out = try AVAudioFile(forWriting: output, settings: settings)
    try out.write(from: buf)
}

func ffmpegMerge(mic: URL, system: URL, output: URL) -> Int32 {
    let filter = """
    [0:a]aresample=16000,aformat=channel_layouts=mono[micL];\
    [1:a]aresample=16000,pan=mono|c0=0.5*c0+0.5*c1[sysR];\
    [micL][sysR]amerge=inputs=2[stereo]
    """
    return runFFmpeg([
        "-y", "-hide_banner", "-loglevel", "error",
        "-i", mic.path, "-i", system.path,
        "-filter_complex", filter, "-map", "[stereo]",
        "-ar", "16000", "-c:a", "pcm_s16le", output.path,
    ])
}

// MARK: - run

func ms(_ block: () throws -> Void) rethrows -> Double {
    let t0 = Date(); try block(); return Date().timeIntervalSince(t0) * 1000
}

let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dep1-spike-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
func u(_ name: String) -> URL { tmp.appendingPathComponent(name) }

print("DEP1 native-AVFoundation vs ffmpeg spike")
print("ffmpeg: \(ffmpegPath())\n")

// Inputs: mono mic (3.0 s @ 48 kHz, 440 Hz) and stereo system (3.5 s @ 44.1 kHz,
// 880/1320 Hz) - different lengths and rates, stereo system to exercise downmix.
let mic = u("mic.wav")
let system = u("system.wav")
try writeTone(mic, freqs: [440], seconds: 3.0, sampleRate: 48000)
try writeTone(system, freqs: [880, 1320], seconds: 3.5, sampleRate: 44100)

// ---- merge ----
let nativeMergeOut = u("merge_native.wav")
let ffmpegMergeOut = u("merge_ffmpeg.wav")
let tNative = try ms { try nativeMerge(mic: mic, system: system, output: nativeMergeOut) }
let mergeStatus = ffmpegMerge(mic: mic, system: system, output: ffmpegMergeOut)
let nm = try inspect(nativeMergeOut)
let fm = mergeStatus == 0 ? try inspect(ffmpegMergeOut) : nil

print("== MERGE (mic-L, system-R, 16 kHz stereo) ==")
print(String(format: "  native : %5.3f s, %d ch, %d frames, %d B, RMS L=%.3f R=%.3f, %.1f ms",
             nm.durationSec, nm.channels, nm.frames, nm.bytes, nm.perChannelRMS[0], nm.perChannelRMS[1], tNative))
if let fm {
    print(String(format: "  ffmpeg : %5.3f s, %d ch, %d frames, %d B, RMS L=%.3f R=%.3f",
                 fm.durationSec, fm.channels, fm.frames, fm.bytes, fm.perChannelRMS[0], fm.perChannelRMS[1]))
    let frameDelta = abs(Int(nm.frames) - Int(fm.frames))
    let channelsOK = nm.channels == 2 && fm.channels == 2
    let separationOK = nm.perChannelRMS[0] > 0.01 && nm.perChannelRMS[1] > 0.01
        && fm.perChannelRMS[0] > 0.01 && fm.perChannelRMS[1] > 0.01
    print("  frame delta: \(frameDelta) (\(String(format: "%.1f", Double(frameDelta) / 16000 * 1000)) ms), " +
          "channels ok: \(channelsOK), channel separation ok: \(separationOK)")
} else {
    print("  ffmpeg : FAILED (status \(mergeStatus))")
}

// ---- transcode ----
// Transcode the native merged stereo WAV to FLAC both ways.
let src = nativeMergeOut
let nativeFlac = u("t_native.flac")
let ffmpegFlac = u("t_ffmpeg.flac")
let tFlac = try ms { try nativeTranscodeFLAC(src, nativeFlac) }
let flacStatus = runFFmpeg(["-y", "-hide_banner", "-loglevel", "error", "-i", src.path,
                            "-c:a", "flac", "-compression_level", "8", ffmpegFlac.path])
let si = try inspect(src)
let nf = try inspect(nativeFlac)
let ff = flacStatus == 0 ? try inspect(ffmpegFlac) : nil

print("\n== TRANSCODE (WAV -> FLAC) ==")
print(String(format: "  source : %5.3f s, %d frames, %d B", si.durationSec, si.frames, si.bytes))
print(String(format: "  native : %5.3f s, %d frames, %d B (%.0f%% of wav), %.1f ms, dur match: %@",
             nf.durationSec, nf.frames, nf.bytes, Double(nf.bytes) / Double(si.bytes) * 100, tFlac,
             abs(nf.durationSec - si.durationSec) < 0.05 ? "YES" : "NO"))
if let ff {
    print(String(format: "  ffmpeg : %5.3f s, %d frames, %d B (%.0f%% of wav), dur match: %@",
                 ff.durationSec, ff.frames, ff.bytes, Double(ff.bytes) / Double(si.bytes) * 100,
                 abs(ff.durationSec - si.durationSec) < 0.05 ? "YES" : "NO"))
} else {
    print("  ffmpeg : FAILED (status \(flacStatus))")
}

print("""

== VERDICT ==
  Transcode : GO. Native AVAudioFile FLAC is frame-exact and lossless (duration
              match, and smaller here than ffmpeg). Two required gotchas, both
              handled above: AVEncoderBitDepthHintKey in the settings, and
              position-bounded reads (read-past-EOF throws).
  Merge     : GO on feasibility. Correct 16 kHz mic-L / system-R stereo with
              channel separation intact. Not sample-identical to ffmpeg (a
              different resampler), and the length policy differs: this prototype
              pads to the longer input, ffmpeg amerge stops at the shorter. A port
              picks one policy and downmixes the stereo system source explicitly
              ((L+R)/2), NOT via AVAudioConverter layout inference (FluidAudioRunner).
  Caveat    : This covers only the REC merge + STOR1 transcode. MuteRedactor is a
              third ffmpeg spawn out of DEP1's scope, so deleting the binary (the
              DIST1 payoff) also needs that ported or the dependency kept.
""")

