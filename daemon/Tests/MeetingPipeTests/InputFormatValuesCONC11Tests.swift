import AVFoundation
import XCTest
@testable import MeetingPipe

/// CONC11: the input node's format crosses from the engine queue to main as plain values, and
/// the format rebuilt from them is the one the tap and the converter decisions used before.
final class InputFormatValuesCONC11Tests: XCTestCase {

    func test_monoAndStereoRebuildToAnEqualFormat() throws {
        for channels: AVAudioChannelCount in [1, 2] {
            for interleaved in [false, true] {
                let original = try XCTUnwrap(AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: channels, interleaved: interleaved
                ))
                let rebuilt = try XCTUnwrap(InputFormatValues(original).makeFormat())
                XCTAssertEqual(rebuilt, original, "\(channels) ch interleaved=\(interleaved)")
            }
        }
    }

    /// The comparison recovery makes (`liveFormat != fileFormat`) gives the same answer on a
    /// rebuilt format: a mono 48 kHz input needs no converter, a 24 kHz one does.
    func test_aRebuiltFormatComparesToTheMicFileFormatAsTheOriginalDid() throws {
        let fileFormat = try XCTUnwrap(MeetingRecorder.monoCaptureFormat(sampleRate: 48_000))
        let same = try XCTUnwrap(InputFormatValues(sampleRate: 48_000, channelCount: 1).makeFormat())
        let other = try XCTUnwrap(InputFormatValues(sampleRate: 24_000, channelCount: 1).makeFormat())
        XCTAssertEqual(same, fileFormat)
        XCTAssertNotEqual(other, fileFormat)
    }

    func test_aMultichannelFormatKeepsItsLayout() throws {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4))
        let original = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44_100, interleaved: false, channelLayout: layout
        )
        let values = InputFormatValues(original)
        XCTAssertEqual(values.channelCount, 4)
        let rebuilt = try XCTUnwrap(values.makeFormat())
        XCTAssertEqual(rebuilt.channelCount, 4)
        XCTAssertEqual(rebuilt.sampleRate, 44_100)
        XCTAssertEqual(rebuilt, original)
    }

    /// No tag (a layout described channel by channel) still rebuilds, as discrete channels.
    func test_aMultichannelReadWithNoTagRebuildsAsDiscreteChannels() throws {
        let rebuilt = try XCTUnwrap(InputFormatValues(sampleRate: 48_000, channelCount: 6).makeFormat())
        XCTAssertEqual(rebuilt.channelCount, 6)
    }

    /// A 0-channel read still rebuilds, as the object always came through, so the decision about
    /// it stays where it was: `GuardedTapInstall` refuses it, the recorder does not pre-empt it.
    func test_aZeroChannelReadStillRebuildsSoTheTapGuardDecides() throws {
        let rebuilt = try XCTUnwrap(InputFormatValues(sampleRate: 48_000, channelCount: 0).makeFormat())
        XCTAssertEqual(rebuilt.channelCount, 0)
    }

    /// Both bounded format reads hand back values, never the object (the SDK 27 warning sites).
    func test_neitherFormatReadReturnsTheFormatObjectAcrossIsolation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let code = try String(
            contentsOf: root.appendingPathComponent("Sources/MeetingPipe/MeetingRecorder.swift"), encoding: .utf8
        )
        for site in ["start_format_read", "input_format_read"] {
            let call = try XCTUnwrap(
                code.components(separatedBy: "engineCall(site: \"\(site)\"").dropFirst().first?
                    .components(separatedBy: "})").first,
                "the \(site) read moved; re-read this fence"
            )
            XCTAssertTrue(
                call.contains("InputFormatValues(engine.inputNode.outputFormat(forBus: 0))"),
                "\(site) has to return plain values: AVAudioFormat is Sendable only from macOS 26"
            )
        }
    }
}
