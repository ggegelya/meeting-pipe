import XCTest
@testable import MeetingPipe

/// REC14: an unclean exit discarded the longer system leg.
///
/// `20260814-163455`, the REC13 incident. The stop deadlocked, `kill -9` was required, and the
/// recovered final was 2798.5 s of a 113-minute call: the mic's length exactly. The system leg held
/// 1,314,082,816 bytes, which at 48 kHz mono float32 is 6844 s, so roughly 67 minutes of the far
/// side was discarded.
///
/// **The mechanism is not the one the spec named, and this suite pins the real one.** An
/// unfinalized WAV does not read as unreadable: `AVAudioFile` writes the `data` chunk's size as a
/// placeholder and patches it when the handle closes, so a killed process leaves `0` there while
/// the samples sit on disk. `audioDurationSec` returned `0.0`, `mergeLengths` therefore saw two
/// readable durations, and `max(2798.5, offset + 0)` cut to the mic. The nil fallback the spec
/// targeted never ran, so re-biasing it would have left the loss in place with a green test.
final class MergeLengthFallbackTests: XCTestCase {

    private typealias P = RecordingPostProcessor

    /// 48 kHz mono float32, the capture format: 4 bytes a frame, 192000 a second.
    private let byteRate: UInt32 = 192_000
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec14-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// Builds a PCM WAV whose payload is `seconds` long. `declaredDataSize` is what the `data`
    /// chunk's size field says, which is the placeholder `0` for a file whose writer was killed.
    @discardableResult
    private func makeWav(_ name: String, seconds: Double, declaredDataSize: UInt32?) throws -> URL {
        let payload = Int(Double(byteRate) * seconds)
        var body = Data()
        body.append(contentsOf: Array("fmt ".utf8))
        body.append(le32(16))
        body.append(le16(3))              // IEEE float
        body.append(le16(1))              // mono
        body.append(le32(48_000))
        body.append(le32(byteRate))
        body.append(le16(4))
        body.append(le16(32))
        body.append(contentsOf: Array("data".utf8))
        body.append(le32(declaredDataSize ?? UInt32(payload)))
        body.append(Data(count: payload))

        var file = Data()
        file.append(contentsOf: Array("RIFF".utf8))
        file.append(le32(UInt32(4 + body.count)))
        file.append(contentsOf: Array("WAVE".utf8))
        file.append(body)

        let url = dir.appendingPathComponent(name)
        try file.write(to: url)
        return url
    }

    private func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    // MARK: - Route B: the duration is derived, not trusted

    /// The normal path is unchanged: a finalized header is authoritative.
    func test_a_finalized_file_reads_its_declared_duration() throws {
        let url = try makeWav("clean.wav", seconds: 10, declaredDataSize: nil)
        XCTAssertEqual(try XCTUnwrap(P.audioDurationSec(of: url)), 10, accuracy: 0.001)
    }

    /// The reported case. Against `main` this returned 0.0, which is what let a zero win a `max()`.
    func test_an_unfinalized_file_is_measured_from_its_real_size() throws {
        let url = try makeWav("dirty.wav", seconds: 10, declaredDataSize: 0)
        XCTAssertEqual(
            try XCTUnwrap(P.audioDurationSec(of: url)), 10, accuracy: 0.001,
            "a killed writer leaves the data size at 0 while the samples are on disk"
        )
    }

    /// A truncated file declares more than it holds, so the declared size is capped by reality
    /// rather than believed.
    func test_a_truncated_file_is_capped_by_what_is_on_disk() throws {
        let url = try makeWav("short.wav", seconds: 2, declaredDataSize: UInt32(byteRate) * 60)
        let measured = try XCTUnwrap(P.audioDurationSec(of: url))
        XCTAssertEqual(measured, 2, accuracy: 0.001, "the header claimed a minute it does not have")
    }

    /// The incident's own numbers, as a fixture. 1,314,082,816 bytes of system audio is 6844 s,
    /// which is the 114 minutes that were thrown away.
    func test_the_incident_numbers_reproduce() {
        XCTAssertEqual(Double(1_314_082_816) / Double(byteRate), 6844.18, accuracy: 0.01)
        XCTAssertEqual(Double(537_310_524) / Double(byteRate), 2798.49, accuracy: 0.01)
    }

    /// Nothing to measure at all still reads as unreadable rather than as zero.
    func test_a_file_with_no_payload_and_no_declared_size_is_unreadable() throws {
        let url = try makeWav("empty.wav", seconds: 0, declaredDataSize: 0)
        XCTAssertNil(P.audioDurationSec(of: url))
    }

    func test_a_missing_file_is_unreadable() {
        XCTAssertNil(P.audioDurationSec(of: dir.appendingPathComponent("nope.wav")))
    }

    // MARK: - The length policy

    /// The exact shape of the loss, at the policy level: a zero must never be treated as a
    /// measurement, because `max(mic, 0)` is the mic and the system leg vanishes.
    func test_a_zero_duration_is_not_a_measurement() {
        let lengths = P.mergeLengths(micDurationSec: 2798.5, systemDurationSec: 0, systemHeadOffsetSec: 0)
        XCTAssertNil(
            lengths.targetDurationSec,
            "a zero system duration is an unpatched header, not a zero-length capture"
        )
        XCTAssertFalse(lengths.padMic)
    }

    /// Both legs measured, system longer. This is the case the incident would have taken with the
    /// derived duration in hand, and the whole call survives.
    func test_a_longer_system_leg_sets_the_target() throws {
        let lengths = P.mergeLengths(
            micDurationSec: 2798.5, systemDurationSec: 6844.18, systemHeadOffsetSec: 0
        )
        XCTAssertEqual(try XCTUnwrap(lengths.targetDurationSec), 6844.18, accuracy: 0.01)
        XCTAssertTrue(lengths.padMic, "the mic is padded up to the longer system leg")
    }

    /// The other direction, so the fix is not a mirror of the bug: a longer mic still survives
    /// whole, which is REC9's guarantee and is not reopened.
    func test_a_longer_mic_leg_still_survives_in_full() throws {
        let lengths = P.mergeLengths(
            micDurationSec: 3600, systemDurationSec: 1200, systemHeadOffsetSec: 0
        )
        XCTAssertEqual(try XCTUnwrap(lengths.targetDurationSec), 3600, accuracy: 0.01)
    }

    /// Only the system leg measured. Cutting at the mic here is what discarded the longer channel,
    /// so the target covers the leg that is actually known.
    func test_when_only_the_system_leg_measures_the_target_covers_it() throws {
        let lengths = P.mergeLengths(
            micDurationSec: nil, systemDurationSec: 6844.18, systemHeadOffsetSec: 12
        )
        XCTAssertEqual(try XCTUnwrap(lengths.targetDurationSec), 6856.18, accuracy: 0.01)
        XCTAssertTrue(lengths.padMic)
        XCTAssertEqual(lengths.systemDelayMs, 12_000, "the late system leg is still delayed into place")
    }

    /// With nothing measurable about the system leg there is no length to prefer over the mic's, so
    /// REC9's bias stands. That is the case REC9 was reasoning about and it is left alone.
    func test_with_no_system_measurement_the_mic_bias_stands() {
        let lengths = P.mergeLengths(micDurationSec: 3600, systemDurationSec: nil, systemHeadOffsetSec: 0)
        XCTAssertNil(lengths.targetDurationSec)
        XCTAssertFalse(lengths.padMic, "padding both legs with no cut makes the merge infinite")
        XCTAssertEqual(lengths.expectedDurationSec, 3600)
    }

    /// Neither leg measurable: byte floor only.
    func test_with_nothing_measurable_there_is_no_expectation() {
        let lengths = P.mergeLengths(micDurationSec: nil, systemDurationSec: nil, systemHeadOffsetSec: 0)
        XCTAssertNil(lengths.targetDurationSec)
        XCTAssertNil(lengths.expectedDurationSec)
        XCTAssertFalse(lengths.padMic)
    }

    // MARK: - The orphan-recovery path, where an unpatched header actually arrives

    /// End to end over two real files in the incident's shape: a mic whose handle closed and a
    /// system leg killed mid-write. The merge must reach the system leg's length.
    func test_the_orphan_shape_reaches_the_system_leg() throws {
        let mic = try makeWav("orphan.mic.wav", seconds: 2798.5, declaredDataSize: nil)
        let system = try makeWav("orphan.system.wav", seconds: 6844.18, declaredDataSize: 0)

        let lengths = P.mergeLengths(
            micDurationSec: P.audioDurationSec(of: mic),
            systemDurationSec: P.audioDurationSec(of: system),
            // recoverOrphan passes 0: a crash leaves no record of when either channel began.
            systemHeadOffsetSec: 0
        )

        XCTAssertEqual(
            try XCTUnwrap(lengths.targetDurationSec), 6844.18, accuracy: 0.05,
            "the recovered final must cover the whole call, not end with the mic"
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(lengths.targetDurationSec), 2798.5,
            "ending at the mic's 2798.5 s is the 2026-08-14 loss"
        )
    }
}
