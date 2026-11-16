import AppKit
import XCTest
@testable import MeetingPipe

/// REC18: the prompt's activity pulse opens no device. It follows the discovery watcher's mic-busy
/// signal, where the live meter it replaced started its own `AVAudioEngine` on the input while the
/// consent question was on screen.
@MainActor
final class MicActivityPulseREC18Tests: XCTestCase {

    func test_the_pulse_rests_without_a_busy_mic_and_breathes_with_one() {
        XCTAssertEqual(MicActivityPulse.appearance(micBusy: false, reduceMotion: false), .resting)
        XCTAssertEqual(MicActivityPulse.appearance(micBusy: false, reduceMotion: true), .resting)
        XCTAssertEqual(MicActivityPulse.appearance(micBusy: true, reduceMotion: false), .pulsing)
        XCTAssertEqual(MicActivityPulse.appearance(micBusy: true, reduceMotion: true), .lit, "Reduce Motion: lit, still")
        XCTAssertLessThan(MicActivityPulse.Appearance.resting.opacity, MicActivityPulse.Appearance.lit.opacity)
    }

    func test_the_view_follows_a_fake_mic_busy_signal() {
        let view = MicActivityPulseView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        XCTAssertEqual(view.pulseAppearance, .resting)
        XCTAssertFalse(view.isPulsing, "idle when nothing holds the mic")

        view.setMicBusy(true)
        let expected = MicActivityPulse.appearance(
            micBusy: true, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        XCTAssertEqual(view.pulseAppearance, expected)
        XCTAssertEqual(view.isPulsing, expected == .pulsing)

        view.setMicBusy(false)
        XCTAssertEqual(view.pulseAppearance, .resting)
        XCTAssertFalse(view.isPulsing, "back to idle when the signal goes false")
    }

    // MARK: - No device is opened while the prompt is up

    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// No seam reaches the prompt's AppKit without a screen, so this is a source fence: the prompt
    /// owns no engine, installs no tap, and the meter type is gone from the tree.
    func test_the_prompt_owns_no_audio_engine_and_installs_no_tap() throws {
        let prompt = try source("Sources/MeetingPipe/MeetingPromptWindow.swift")
        for forbidden in ["AVAudioEngine", "installTap", "MicLevelMonitor", "inputNode", "import AVFoundation", "import AVFAudio"] {
            XCTAssertFalse(prompt.contains(forbidden), "MeetingPromptWindow must not reference \(forbidden)")
        }
        XCTAssertTrue(prompt.contains("micPulse?.setMicBusy(micBusy)"), "present seeds the pulse from the signal")
        let pulse = try source("Sources/MeetingPipe/Design/MicActivityPulseView.swift")
        XCTAssertFalse(pulse.contains("import AV") || pulse.contains("AVAudioEngine(") || pulse.contains("installTap"), "the pulse reads no audio")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Sources/MeetingPipe/Design/MicLevelMonitor.swift").path
        ))
    }

    /// The signal has to reach the prompt, or the pulse never moves (END9's shape: a feature fed by
    /// nobody).
    func test_the_discovery_watchers_mic_busy_signal_feeds_the_prompt() throws {
        let coordinator = try source("Sources/MeetingPipe/Coordinator.swift")
        let hook = try XCTUnwrap(coordinator.range(of: "discoveryWatcher.onMicBusyBundle = { [weak self] bundle in"))
        let body = coordinator[hook.upperBound...].prefix(400)
        XCTAssertTrue(body.contains("self?.promptWindow.setMicBusy(bundle != nil)"))
    }
}
