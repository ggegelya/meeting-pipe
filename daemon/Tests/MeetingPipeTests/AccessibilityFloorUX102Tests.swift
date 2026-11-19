import AppKit
import XCTest
@testable import MeetingPipe

/// UX102: PRODUCT.md's accessibility floor on the controls it names. Reduce Motion stills the
/// recording pulses, the processing ring, the HUD dot and both panels' fades; the prompt's
/// workflow chip has a name; the Audio tab's waveform steps by keyboard and VoiceOver; the HUD
/// meter stays at zero after Mic lost; and the elapsed clock comes back after a reverted end hold.
final class AccessibilityFloorUX102Tests: XCTestCase {
    private let samples: [TimeInterval] = stride(from: 0.0, through: 3.2, by: 0.1).map { 800_000_000 + $0 }

    // MARK: Reduce Motion, Library indicators

    func test_reduced_pulse_envelopes_are_constant_at_every_phase() {
        let toolbar = Set(samples.map { PulseEnvelope.toolbarAura(at: $0, reduceMotion: true) })
        let steady = Set(samples.map { PulseEnvelope.steadyDot(at: $0, reduceMotion: true) })
        let ring = Set(samples.map { PulseEnvelope.ringDegrees(at: $0, reduceMotion: true) })
        XCTAssertEqual(toolbar, [1], "the toolbar aura is held, not looped")
        XCTAssertEqual(steady, [1], "the row dot sits at full opacity")
        XCTAssertEqual(ring, [0], "a still, partial ring")
    }

    func test_normal_motion_keeps_todays_ranges() {
        let toolbar = samples.map { PulseEnvelope.toolbarAura(at: $0, reduceMotion: false) }
        XCTAssertEqual(toolbar.min()!, 0, accuracy: 0.02)
        XCTAssertEqual(toolbar.max()!, 1, accuracy: 0.02)
        let steady = samples.map { PulseEnvelope.steadyDot(at: $0, reduceMotion: false) }
        XCTAssertEqual(steady.min()!, 0.35, accuracy: 0.02)
        XCTAssertEqual(steady.max()!, 1, accuracy: 0.02)
        let ring = samples.map { PulseEnvelope.ringDegrees(at: $0, reduceMotion: false) }
        XCTAssertGreaterThan(Set(ring).count, 5, "the ring still turns")
        XCTAssertTrue(ring.allSatisfy { (0..<360).contains($0) })
    }

    /// The reduced path must stop the redraws too, not only the movement: each indicator's body
    /// reads the setting and branches before its `TimelineView`.
    func test_each_indicator_reads_reduce_motion_before_its_timeline() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingPipe")
        for (file, type) in [("LibraryToolbar.swift", "struct PulseDot"),
                             ("LibraryChrome.swift", "struct MPSteadyPulseDot"),
                             ("LibraryChrome.swift", "struct MPRingSpinner")] {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            guard let start = text.range(of: type) else { return XCTFail("\(type) not found in \(file)") }
            let tail = String(text[start.upperBound...])
            let end = tail.range(of: "\n}\n").map { String(tail[..<$0.lowerBound]) } ?? tail
            XCTAssertTrue(end.contains("@Environment(\\.accessibilityReduceMotion)"), type)
            let branch = try XCTUnwrap(end.range(of: "if reduceMotion {"), type)
            let timeline = try XCTUnwrap(end.range(of: "TimelineView("), type)
            XCTAssertLessThan(branch.lowerBound, timeline.lowerBound, "\(type) branches before the timeline")
        }
    }

    // MARK: Reduce Motion, panels

    func test_panel_motion_under_reduce_motion_is_still_and_instant() {
        let reduced = PanelMotion.decide(reduceMotion: true)
        XCTAssertFalse(reduced.pulses, "no HUD pulse animation")
        XCTAssertEqual(reduced.fadeIn, 0)
        XCTAssertEqual(reduced.fadeOut, 0)
    }

    func test_panel_motion_normally_keeps_todays_values() {
        let normal = PanelMotion.decide(reduceMotion: false)
        XCTAssertTrue(normal.pulses)
        XCTAssertEqual(normal.fadeIn, MPMotion.durBase)
        XCTAssertEqual(normal.fadeOut, MPMotion.durFast + 0.03, accuracy: 1e-9)
    }

    /// Both panels' present and dismiss fades go through the one decision.
    func test_both_panels_fade_through_panel_motion() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingPipe")
        for file in ["RecordingHUDWindow.swift", "MeetingPromptWindow.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains("ctx.duration = PanelMotion.decide(reduceMotion: MPMotion.reduceMotion).fadeIn"), file)
            XCTAssertTrue(text.contains("ctx.duration = PanelMotion.decide(reduceMotion: MPMotion.reduceMotion).fadeOut"), file)
            XCTAssertFalse(text.contains("ctx.duration = MPMotion.durFast + 0.03"), "\(file) has an unchecked fade-out")
        }
    }

    // MARK: The workflow chip

    @MainActor
    func test_workflow_chip_is_named_by_its_workflow_and_says_what_it_does() {
        let chip = WorkflowChipView()
        chip.workflowName = "Client work · NDA"
        XCTAssertEqual(chip.accessibilityLabel(), "Client work · NDA")
        XCTAssertEqual(chip.accessibilityHelp(), "Change workflow")
        XCTAssertEqual(chip.toolTip, "Change workflow")
        chip.workflowName = "General"
        XCTAssertEqual(chip.accessibilityLabel(), "General", "follows a workflow change")
    }

    // MARK: The HUD meter

    func test_meter_tick_writes_zero_while_mic_lost_or_off_the_record() {
        var reads = 0
        let loud: () -> Float = { reads += 1; return -3 }
        XCTAssertEqual(RecordingHUDWindow.meterTickLevel(micCaptureLost: true, offRecord: false, providerDb: loud), 0)
        XCTAssertEqual(RecordingHUDWindow.meterTickLevel(micCaptureLost: false, offRecord: true, providerDb: loud), 0)
        XCTAssertEqual(RecordingHUDWindow.meterTickLevel(micCaptureLost: true, offRecord: true, providerDb: loud), 0)
        XCTAssertEqual(reads, 0, "a gated tick does not read the frozen level at all")
        // Back on the record (setOffTheRecord(false)) with the mic live: live levels resume.
        XCTAssertEqual(
            RecordingHUDWindow.meterTickLevel(micCaptureLost: false, offRecord: false, providerDb: loud),
            RecordingHUDWindow.normalizedLevel(db: -3)
        )
        XCTAssertGreaterThan(RecordingHUDWindow.normalizedLevel(db: -3), 0.9)
    }

    // MARK: The elapsed clock

    @MainActor
    func test_elapsed_clock_returns_to_fg_after_a_reverted_end_hold() {
        let hud = RecordingHUDWindow()
        _ = hud.makePanel(source: nil, workflow: nil)
        XCTAssertEqual(hud.elapsedLabel?.textColor, MPColors.fg, "built in fg")
        hud.setConfirmingEnd(true)
        XCTAssertEqual(hud.elapsedLabel?.textColor, MPColors.fgSubtle)
        hud.setConfirmingEnd(false)
        XCTAssertEqual(hud.elapsedLabel?.textColor, MPColors.fg, "not left muted for the rest of the recording")
        hud.dismiss(animated: false)
    }

    // MARK: The waveform

    func test_waveform_step_moves_by_the_step_and_clamps_at_both_ends() {
        let step = WaveformSeek.stepSec
        XCTAssertEqual(step, 5)
        XCTAssertEqual(WaveformSeek.step(from: 30, forward: true, durationSec: 600), 30 + step)
        XCTAssertEqual(WaveformSeek.step(from: 30, forward: false, durationSec: 600), 30 - step)
        XCTAssertEqual(WaveformSeek.step(from: 2, forward: false, durationSec: 600), 0, "clamps at the start")
        XCTAssertEqual(WaveformSeek.step(from: 598, forward: true, durationSec: 600), 600, "clamps at the end")
        XCTAssertEqual(WaveformSeek.step(from: 0, forward: true, durationSec: 0), 0)
    }

    func test_waveform_value_reads_the_playhead_of_the_duration() {
        XCTAssertEqual(WaveformSeek.value(current: 65, durationSec: 3_725), "1:05 of 1:02:05")
    }
}
