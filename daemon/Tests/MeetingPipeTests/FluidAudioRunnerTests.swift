import AVFoundation
import XCTest
@testable import MeetingPipe

/// REC20 item 3a: `readMonoFloat32` reads block-wise into one preallocated mono array, and the
/// samples it hands the ASR and the diarizer are bit-identical to the whole-file read it replaced.
/// That identity is the whole licence for the change: DIAR2 tuned the diarizer against this array,
/// so a read that moved one sample would move speaker output nobody re-measured.
final class FluidAudioRunnerTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec20-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    /// The read this task replaced, kept here as the reference: one buffer for the whole file,
    /// `mixDownToMono`, then the same resample step.
    private func wholeFileReference(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: buffer)
        let mono = FluidAudioRunner.mixDownToMono(buffer)
        if file.processingFormat.sampleRate == 16_000 { return mono }
        return try FluidAudioRunner.resampleMono(
            mono, from: file.processingFormat.sampleRate, to: 16_000, url: url
        )
    }

    /// A deterministic, non-trivial signal per channel: a sum of two tones and a channel offset,
    /// so a mix that swaps channel order or drops a scale shows up in the low bits.
    private func writeFile(
        _ url: URL,
        sampleRate: Double,
        channels: AVAudioChannelCount,
        frames: Int,
        int16: Bool = false,
        sample: (Int, Int) -> Float = { c, i in
            0.4 * sinf(Float(i) * 0.013 * Float(c + 1)) + 0.3 * sinf(Float(i) * 0.0021) + 0.01 * Float(c)
        }
    ) throws {
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        if int16 {
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
        } else {
            settings[AVLinearPCMBitDepthKey] = 32
            settings[AVLinearPCMIsFloatKey] = true
        }
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let chunk = 65_536
        var written = 0
        while written < frames {
            let n = min(chunk, frames - written)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)))
            buffer.frameLength = AVAudioFrameCount(n)
            for c in 0..<Int(channels) {
                let ptr = buffer.floatChannelData![c]
                for i in 0..<n { ptr[i] = sample(c, written + i) }
            }
            try file.write(from: buffer)
            written += n
        }
    }

    /// The production shape: the stop-time final is 16 kHz stereo s16. The length is two full
    /// default blocks plus a remainder, so the last, short block is exercised.
    func test_block_read_is_bit_identical_on_16khz_stereo_s16() throws {
        let url = dir.appendingPathComponent("final.wav")
        try writeFile(url, sampleRate: 16_000, channels: 2, frames: 2 * 480_000 + 12_345, int16: true)

        let reference = try wholeFileReference(url)
        let blockwise = try FluidAudioRunner.readMonoFloat32(from: url)
        XCTAssertEqual(blockwise.count, 2 * 480_000 + 12_345)
        XCTAssertTrue(blockwise == reference, "the block-wise read moved samples")

        let smallBlocks = try FluidAudioRunner.readMonoFloat32(from: url, blockFrames: 4_097)
        XCTAssertTrue(smallBlocks == reference, "block size must not matter")
    }

    func test_block_read_is_bit_identical_through_the_resample_path() throws {
        let url = dir.appendingPathComponent("old.wav")
        try writeFile(url, sampleRate: 44_100, channels: 2, frames: 44_100 * 3 + 777)

        let reference = try wholeFileReference(url)
        let blockwise = try FluidAudioRunner.readMonoFloat32(from: url, blockFrames: 10_000)
        XCTAssertFalse(blockwise.isEmpty)
        XCTAssertTrue(blockwise == reference, "the resample path's samples moved")
    }

    func test_block_read_of_a_mono_file_is_a_straight_copy() throws {
        let url = dir.appendingPathComponent("mono.wav")
        try writeFile(url, sampleRate: 16_000, channels: 1, frames: 50_001, int16: true)
        let blockwise = try FluidAudioRunner.readMonoFloat32(from: url, blockFrames: 8_192)
        XCTAssertEqual(blockwise.count, 50_001)
        XCTAssertTrue(blockwise == (try wholeFileReference(url)))
    }

    /// Found while writing the test above: on a mono Float32 WAV a single `read(into:)` of the
    /// whole file returned 49,152 of 50,001 frames, and the old whole-file read kept the short
    /// buffer without a word. The block loop keeps reading until the header's length is met.
    func test_block_read_keeps_reading_where_one_whole_file_read_comes_back_short() throws {
        let url = dir.appendingPathComponent("mono-float.wav")
        try writeFile(url, sampleRate: 16_000, channels: 1, frames: 50_001)
        XCTAssertEqual(try FluidAudioRunner.readMonoFloat32(from: url, blockFrames: 8_192).count, 50_001)
    }

    func test_an_empty_file_reads_as_nothing() throws {
        let url = dir.appendingPathComponent("empty.wav")
        try writeFile(url, sampleRate: 16_000, channels: 2, frames: 0)
        XCTAssertEqual(try FluidAudioRunner.readMonoFloat32(from: url), [])
    }

    /// The in-place block mix is the same arithmetic as `mixDownToMono`.
    func test_the_in_place_mix_matches_mixDownToMono() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        buffer.frameLength = 3
        let l: [Float] = [0.1, -0.7, 0.33]
        let r: [Float] = [0.9, 0.2, -0.33]
        for i in 0..<3 {
            buffer.floatChannelData![0][i] = l[i]
            buffer.floatChannelData![1][i] = r[i]
        }
        var out = [Float](repeating: 0, count: 3)
        out.withUnsafeMutableBufferPointer { FluidAudioRunner.mixDownToMono(buffer, into: $0.baseAddress!) }
        XCTAssertEqual(out, FluidAudioRunner.mixDownToMono(buffer))
    }
}
