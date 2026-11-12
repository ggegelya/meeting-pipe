import XCTest
@testable import MeetingPipe

/// REC19: a capture intermediate over 4 GiB is BW64, not RIFF, once its writer closes it.
///
/// Measured on macOS 27.2 (2026-11-12): 14,401 s of 48 kHz stereo Float32 written through
/// `AVAudioFile` never failed a write. At close the file's magic was `BW64`, the 28-byte `JUNK`
/// chunk the writer reserves up front had become `ds64`, and the 32-bit `data` size read
/// `0xFFFFFFFF`. `audioDurationSec` only accepted `RIFF`, so it returned nil, and `mergeLengths`
/// ran every merge past 3 h 6 min with no `-t` cut, ending at the mic.
///
/// The fixtures mirror that header byte for byte (`ds64`, `fmt `, an `FLLR` pad that puts the
/// payload at 4096, then `data`). The >4 GiB case is a sparse file, so it costs no disk.
final class AudioDurationBW64REC19Tests: XCTestCase {

    private typealias P = RecordingPostProcessor

    /// 48 kHz stereo Float32, the system channel's capture format: 384,000 bytes a second.
    private let byteRate: UInt32 = 384_000
    private let payloadOffset = 4096
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec19-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func le64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    /// The header `AVAudioFile` leaves on a closed >4 GiB WAV, up to the start of the payload.
    private func wideHeader(magic: String, dataSize: UInt64) -> Data {
        var h = Data()
        h.append(contentsOf: Array(magic.utf8))
        h.append(le32(.max))
        h.append(contentsOf: Array("WAVE".utf8))
        h.append(contentsOf: Array("ds64".utf8))
        h.append(le32(28))
        h.append(le64(dataSize + UInt64(payloadOffset) - 8))   // RIFF size
        h.append(le64(dataSize))                               // data size
        h.append(le64(dataSize / 8))                           // sample frames
        h.append(le32(0))                                      // table length
        h.append(contentsOf: Array("fmt ".utf8))
        h.append(le32(16))
        h.append(le16(3))              // IEEE float
        h.append(le16(2))              // stereo
        h.append(le32(48_000))
        h.append(le32(byteRate))
        h.append(le16(8))
        h.append(le16(32))
        // Pad chunk so the payload lands at 4096, as Apple's writer lays it out.
        let padBody = payloadOffset - h.count - 8 - 8
        h.append(contentsOf: Array("FLLR".utf8))
        h.append(le32(UInt32(padBody)))
        h.append(Data(count: padBody))
        h.append(contentsOf: Array("data".utf8))
        h.append(le32(.max))
        precondition(h.count == payloadOffset)
        return h
    }

    /// A wide WAV whose payload is really on disk.
    private func makeWide(_ name: String, magic: String = "BW64", seconds: Double, trailing: Data = Data()) throws -> URL {
        let payload = Int(Double(byteRate) * seconds)
        var file = wideHeader(magic: magic, dataSize: UInt64(payload))
        file.append(Data(count: payload))
        file.append(trailing)
        let url = dir.appendingPathComponent(name)
        try file.write(to: url)
        return url
    }

    func test_a_closed_bw64_intermediate_reads_its_64_bit_data_size() throws {
        let url = try makeWide("small.system.wav", seconds: 1)
        XCTAssertEqual(try XCTUnwrap(P.audioDurationSec(of: url), "BW64 must not read as unreadable"), 1, accuracy: 0.001)
    }

    /// `ds64`'s size is the authority, as the 32-bit size is for RIFF: bytes after the payload
    /// (a trailing chunk) must not lengthen the recording.
    func test_the_ds64_size_wins_over_trailing_bytes() throws {
        var trailing = Data(Array("LIST".utf8))
        trailing.append(le32(992))
        trailing.append(Data(count: 992))
        let url = try makeWide("trail.system.wav", seconds: 1, trailing: trailing)
        XCTAssertEqual(try XCTUnwrap(P.audioDurationSec(of: url)), 1, accuracy: 0.001)
    }

    /// RF64 is the same layout under the EBU's older name.
    func test_rf64_reads_the_same_way() throws {
        let url = try makeWide("rf.system.wav", magic: "RF64", seconds: 2)
        XCTAssertEqual(try XCTUnwrap(P.audioDurationSec(of: url)), 2, accuracy: 0.001)
    }

    /// The measured file's own numbers: 5,529,984,000 payload bytes, 14,401 s. Sparse, so the
    /// on-disk cap in the reader sees the full length without 5.5 GB of writes.
    func test_the_measured_14401_second_intermediate_reads_past_4_gib() throws {
        let dataSize: UInt64 = 5_529_984_000
        let url = dir.appendingPathComponent("measured.system.wav")
        try wideHeader(magic: "BW64", dataSize: dataSize).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(payloadOffset) + dataSize)
        try handle.close()
        XCTAssertGreaterThan(P.fileSize(url), UInt64(UInt32.max), "the fixture must really be past 4 GiB")
        XCTAssertEqual(try XCTUnwrap(P.audioDurationSec(of: url)), 14_401, accuracy: 0.001)
    }

    /// The defect itself, at the length policy: against `main` the system leg read nil, so the
    /// merge took the mic-only branch (no cut, expected length = the mic's) and a far side that
    /// ran past the end of the mic file was cut off and still promoted.
    func test_a_bw64_system_leg_longer_than_the_mic_now_sets_the_cut() throws {
        let dataSize: UInt64 = 5_529_984_000
        let url = dir.appendingPathComponent("long.system.wav")
        try wideHeader(magic: "BW64", dataSize: dataSize).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(payloadOffset) + dataSize)
        try handle.close()

        let lengths = P.mergeLengths(
            micDurationSec: 14_380,
            systemDurationSec: P.audioDurationSec(of: url),
            systemHeadOffsetSec: 0
        )
        XCTAssertTrue(lengths.padMic)
        XCTAssertEqual(try XCTUnwrap(lengths.targetDurationSec), 14_401, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(lengths.expectedDurationSec), 14_401, accuracy: 0.001)
    }

    /// Anything else at offset 0 is still not a WAV.
    func test_an_unknown_magic_is_still_unreadable() throws {
        var file = wideHeader(magic: "XXXX", dataSize: 384_000)
        file.append(Data(count: 384_000))
        let url = dir.appendingPathComponent("bad.wav")
        try file.write(to: url)
        XCTAssertNil(P.audioDurationSec(of: url))
    }
}
