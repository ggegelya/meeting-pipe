import AVFoundation
import Foundation

/// Downsampled per-channel peak data backing the Audio tab's waveform
/// (TECH-A7). The pipeline writes a 16 kHz stereo wav (mic on the left
/// channel, system audio on the right). For rendering we don't need the
/// raw samples — we just need an envelope: one max-abs value per
/// fixed-duration "bin", per channel. A 60-min meeting at 50 bins/sec
/// is 180k floats total → trivial to draw at 60 fps and ~720 KB
/// uncompressed, well inside the spec's 2 s render budget.
///
/// The cache lives under `~/Library/Caches/MeetingPipe/waveforms/` and
/// keys on (file size, modification time). Any change to the underlying
/// wav invalidates the cache implicitly because the header check fails.
struct WaveformPeaks {

    /// Approximate number of peaks per second of audio. 50 gives ~10 ms
    /// resolution — fine enough that the rendered shape is faithful to
    /// the original even at 8× zoom, coarse enough that a 60-min file
    /// stays well under a megabyte.
    static let peaksPerSecond: Int = 50

    /// Per-channel peak arrays. `left[i]` and `right[i]` correspond to
    /// the same time bin; arrays are always equal-length.
    let left: [Float]
    let right: [Float]
    let durationSec: Double

    var binCount: Int { min(left.count, right.count) }
    var binDuration: Double {
        binCount > 0 ? durationSec / Double(binCount) : 0
    }

    /// Map a [0, binCount) bin index back to its starting time. Inverse
    /// of `bin(at:)`.
    func time(of bin: Int) -> Double {
        return Double(bin) * binDuration
    }

    /// Bin index containing `time`. Clamped to the array so a tiny
    /// floating-point overrun at the file end doesn't read past the
    /// buffer.
    func bin(at time: Double) -> Int {
        guard binDuration > 0 else { return 0 }
        let i = Int(time / binDuration)
        return max(0, min(i, binCount - 1))
    }
}

/// Loader + computer for the cached peak data. Stateless namespace; all
/// IO runs off the SwiftUI main actor at the call site.
enum WaveformPeaksLoader {

    /// Magic header for cached peaks. Bumping the version invalidates
    /// every cached file on the next read.
    static let magic: [UInt8] = Array("MPW1".utf8)
    static let formatVersion: UInt8 = 1

    enum LoadError: Error {
        case openFailed(String)
        case unsupportedFormat(String)
        case readFailed(String)
        case cacheWriteFailed(String)
    }

    /// Return cached peaks for `wavURL` if the cache is fresh, otherwise
    /// recompute, write the cache, and return the fresh value. Network
    /// of decisions:
    ///   1. Build a cache path from the stem under
    ///      `~/Library/Caches/MeetingPipe/waveforms`.
    ///   2. If the cached header records the same (size, mtime) as the
    ///      wav on disk, return the cached body straight away.
    ///   3. Otherwise decode the wav with `AVAudioFile`, bin it, and
    ///      write the result.
    static func load(wavURL: URL) throws -> WaveformPeaks {
        let attrs = try FileManager.default.attributesOfItem(atPath: wavURL.path)
        let wavSize = (attrs[.size] as? Int64) ?? 0
        let wavMTime = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)

        let cacheURL = cachePath(for: wavURL)
        if let cached = readCache(at: cacheURL, expectedSize: wavSize, expectedMTime: wavMTime) {
            return cached
        }

        let peaks = try compute(wavURL: wavURL)
        try? writeCache(peaks, at: cacheURL, wavSize: wavSize, wavMTime: wavMTime)
        return peaks
    }

    static func cachePath(for wavURL: URL) -> URL {
        let stem = WaveformPeaksLoader.stem(of: wavURL)
        return cacheDirectory()
            .appendingPathComponent("\(stem).peaks", isDirectory: false)
    }

    static func cacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base
            .appendingPathComponent("MeetingPipe", isDirectory: true)
            .appendingPathComponent("waveforms", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }

    /// Decode `wavURL` into per-channel max-abs bins. Stereo only — the
    /// pipeline never writes a mono wav — but we tolerate mono input by
    /// duplicating the channel into both lanes so the view doesn't
    /// crash on hand-imported files.
    static func compute(wavURL: URL) throws -> WaveformPeaks {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: wavURL)
        } catch {
            throw LoadError.openFailed(error.localizedDescription)
        }
        let inFormat = file.processingFormat
        let sampleRate = inFormat.sampleRate
        let channels = Int(inFormat.channelCount)
        guard sampleRate > 0, channels > 0 else {
            throw LoadError.unsupportedFormat("zero sample rate or channels")
        }
        guard inFormat.commonFormat == .pcmFormatFloat32 else {
            throw LoadError.unsupportedFormat("expected Float32, got \(inFormat.commonFormat.rawValue)")
        }
        let frameCount = AVAudioFrameCount(file.length)
        let totalFrames = Int(file.length)
        let durationSec = sampleRate > 0 ? Double(totalFrames) / sampleRate : 0
        if frameCount == 0 {
            return WaveformPeaks(left: [], right: [], durationSec: 0)
        }

        let binSize = max(1, Int((sampleRate / Double(WaveformPeaks.peaksPerSecond)).rounded()))
        let estBinCount = (totalFrames + binSize - 1) / binSize

        var leftPeaks: [Float] = []
        var rightPeaks: [Float] = []
        leftPeaks.reserveCapacity(estBinCount)
        rightPeaks.reserveCapacity(estBinCount)

        // Read in fixed-size chunks. 64k frames at 16 kHz is ~4 s per
        // chunk, which keeps peak memory low without thrashing
        // AVAudioFile's read path.
        let chunkSize: AVAudioFrameCount = 65_536
        guard let buf = AVAudioPCMBuffer(
            pcmFormat: inFormat, frameCapacity: chunkSize
        ) else {
            throw LoadError.readFailed("could not allocate AVAudioPCMBuffer")
        }

        // Carry-over state across chunk boundaries: a partial bin from
        // the previous read that still needs samples to complete.
        var carryLeft: Float = 0
        var carryRight: Float = 0
        var carryUsed: Int = 0

        while file.framePosition < Int64(frameCount) {
            do {
                try file.read(into: buf)
            } catch {
                throw LoadError.readFailed(error.localizedDescription)
            }
            let n = Int(buf.frameLength)
            if n == 0 { break }
            guard let chData = buf.floatChannelData else {
                throw LoadError.readFailed("missing floatChannelData")
            }
            let leftPtr = chData[0]
            let rightPtr = channels >= 2 ? chData[1] : chData[0]

            var i = 0
            while i < n {
                let need = binSize - carryUsed
                let take = min(need, n - i)
                var lMax: Float = carryLeft
                var rMax: Float = carryRight
                for k in 0..<take {
                    let l = abs(leftPtr[i + k])
                    let r = abs(rightPtr[i + k])
                    if l > lMax { lMax = l }
                    if r > rMax { rMax = r }
                }
                carryLeft = lMax
                carryRight = rMax
                carryUsed += take
                i += take
                if carryUsed >= binSize {
                    leftPeaks.append(carryLeft)
                    rightPeaks.append(carryRight)
                    carryLeft = 0
                    carryRight = 0
                    carryUsed = 0
                }
            }
        }
        if carryUsed > 0 {
            leftPeaks.append(carryLeft)
            rightPeaks.append(carryRight)
        }

        return WaveformPeaks(
            left: leftPeaks,
            right: rightPeaks,
            durationSec: durationSec
        )
    }

    // MARK: Cache I/O

    /// Header (binary, little-endian):
    ///   magic           4 bytes  "MPW1"
    ///   version         1 byte
    ///   channels        1 byte
    ///   reserved        2 bytes
    ///   binCount        4 bytes  UInt32
    ///   durationMillis  8 bytes  Int64
    ///   wavSize         8 bytes  Int64
    ///   wavMTime        8 bytes  Int64  (seconds since 1970)
    /// Total: 36 bytes. Followed by left peaks (Float32 × binCount) then
    /// right peaks (Float32 × binCount).
    private static let headerSize = 36

    static func readCache(
        at url: URL,
        expectedSize: Int64,
        expectedMTime: Date
    ) -> WaveformPeaks? {
        guard let data = try? Data(contentsOf: url), data.count >= headerSize else {
            return nil
        }
        guard data.prefix(4).elementsEqual(magic) else { return nil }
        guard data[4] == formatVersion else { return nil }
        let channels = Int(data[5])
        let binCount = Int(readUInt32LE(data, at: 8))
        let durMillis = readInt64LE(data, at: 12)
        let cachedSize = readInt64LE(data, at: 20)
        let cachedMTime = readInt64LE(data, at: 28)

        let expectedMTimeSec = Int64(expectedMTime.timeIntervalSince1970)
        guard cachedSize == expectedSize, cachedMTime == expectedMTimeSec else {
            return nil
        }
        guard channels >= 1, binCount > 0 else { return nil }
        let bodyBytes = binCount * 2 * MemoryLayout<Float>.size
        guard data.count >= headerSize + bodyBytes else { return nil }

        let left = readFloatArray(data, at: headerSize, count: binCount)
        let right = readFloatArray(
            data, at: headerSize + binCount * MemoryLayout<Float>.size,
            count: binCount
        )
        return WaveformPeaks(
            left: left, right: right,
            durationSec: Double(durMillis) / 1000.0
        )
    }

    static func writeCache(
        _ peaks: WaveformPeaks,
        at url: URL,
        wavSize: Int64,
        wavMTime: Date
    ) throws {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var data = Data(capacity: headerSize + peaks.binCount * 2 * MemoryLayout<Float>.size)
        data.append(contentsOf: magic)
        data.append(formatVersion)
        data.append(UInt8(2))
        data.append(0); data.append(0)
        data.append(contentsOf: uint32LE(UInt32(peaks.binCount)))
        data.append(contentsOf: int64LE(Int64((peaks.durationSec * 1000).rounded())))
        data.append(contentsOf: int64LE(wavSize))
        data.append(contentsOf: int64LE(Int64(wavMTime.timeIntervalSince1970)))
        peaks.left.withUnsafeBufferPointer { bp in
            data.append(UnsafeBufferPointer(start: bp.baseAddress, count: peaks.binCount))
        }
        peaks.right.withUnsafeBufferPointer { bp in
            data.append(UnsafeBufferPointer(start: bp.baseAddress, count: peaks.binCount))
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw LoadError.cacheWriteFailed(error.localizedDescription)
        }
    }

    // MARK: Helpers

    static func stem(of url: URL) -> String {
        let name = url.lastPathComponent
        if let dot = name.firstIndex(of: ".") {
            return String(name[..<dot])
        }
        return name
    }

    private static func readUInt32LE(_ d: Data, at offset: Int) -> UInt32 {
        var v: UInt32 = 0
        withUnsafeMutableBytes(of: &v) { buf in
            _ = d.copyBytes(to: buf, from: offset..<(offset + 4))
        }
        return UInt32(littleEndian: v)
    }

    private static func readInt64LE(_ d: Data, at offset: Int) -> Int64 {
        var v: Int64 = 0
        withUnsafeMutableBytes(of: &v) { buf in
            _ = d.copyBytes(to: buf, from: offset..<(offset + 8))
        }
        return Int64(littleEndian: v)
    }

    private static func readFloatArray(_ d: Data, at offset: Int, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        out.withUnsafeMutableBufferPointer { dst in
            guard let base = dst.baseAddress else { return }
            let raw = UnsafeMutableRawBufferPointer(
                start: base, count: count * MemoryLayout<Float>.size
            )
            _ = d.copyBytes(to: raw, from: offset..<(offset + count * MemoryLayout<Float>.size))
        }
        return out
    }

    private static func uint32LE(_ v: UInt32) -> [UInt8] {
        let le = v.littleEndian
        return withUnsafeBytes(of: le) { Array($0) }
    }

    private static func int64LE(_ v: Int64) -> [UInt8] {
        let le = v.littleEndian
        return withUnsafeBytes(of: le) { Array($0) }
    }
}
