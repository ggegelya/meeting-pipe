import XCTest
@testable import MeetingPipe

/// DIAR3: the two Preferences rows over `transcription.diarization_clustering_threshold`
/// and `summarization.diarize_cleanup` are pure mappings, so the parts that can lie
/// (which position a stored value selects, and whether the cleanup toggle's sentence
/// about NDA meetings is true for the configured backend) are testable without a view.
final class SpeakerAccuracyTests: XCTestCase {

    // MARK: - Position table

    func test_each_position_writes_its_pinned_value() {
        let expected: [(id: String, label: String, value: Double)] = [
            ("distinct", "More distinct", 0.55),
            ("balanced", "Balanced", 0.65),
            ("merge", "Merge more", 0.75),
        ]
        XCTAssertEqual(SpeakerSeparation.all.count, expected.count)
        for (i, want) in expected.enumerated() {
            let got = SpeakerSeparation.all[i]
            XCTAssertEqual(got.id, want.id)
            XCTAssertEqual(got.label, want.label)
            XCTAssertEqual(got.value, want.value)
            XCTAssertEqual(SpeakerSeparation.value(forID: want.id), want.value)
        }
    }

    func test_positions_ascend_so_left_to_right_reads_as_more_to_less_distinct() {
        let values = SpeakerSeparation.all.map(\.value)
        XCTAssertEqual(values, values.sorted(),
                       "the control's labels promise a direction; the values have to follow it")
    }

    func test_every_position_is_inside_fluidaudios_range() {
        for p in SpeakerSeparation.all {
            XCTAssertTrue(SpeakerSeparation.validRange.contains(p.value),
                          "\(p.id) pins \(p.value), which the loader would clamp away")
            XCTAssertEqual(SpeakerSeparation.clamp(p.value), p.value)
        }
    }

    func test_the_shipped_default_lands_on_a_named_position() {
        // Not a restatement of the constant. The property is that a fresh config opens
        // on a position the user can see and reason about, never on Custom, which is a
        // readout rather than a selectable option. DIAR2's sweep moved the default from
        // Balanced to More distinct on 2026-08-04; what must not happen is the default
        // drifting to a value no position pins.
        let id = SpeakerSeparation.id(forValue: ConfigDefaults.diarizationClusteringThreshold)
        XCTAssertNotEqual(id, SpeakerSeparation.customId,
                          "a fresh config would open on Custom, which nobody can pick")
        XCTAssertEqual(id, "distinct")
    }

    // MARK: - Fall-through to Custom

    func test_a_pinned_value_selects_its_position() {
        XCTAssertEqual(SpeakerSeparation.id(forValue: 0.55), "distinct")
        XCTAssertEqual(SpeakerSeparation.id(forValue: 0.65), "balanced")
        XCTAssertEqual(SpeakerSeparation.id(forValue: 0.75), "merge")
    }

    func test_a_non_preset_value_falls_through_to_custom() {
        for value in [0.5, 0.6, 0.7, 0.72, 0.9] {
            XCTAssertEqual(SpeakerSeparation.id(forValue: value), SpeakerSeparation.customId,
                           "\(value) is not pinned by any position and must read as Custom")
        }
    }

    func test_custom_is_never_a_target() {
        XCTAssertNil(SpeakerSeparation.value(forID: SpeakerSeparation.customId))
        XCTAssertNil(SpeakerSeparation.value(forID: "not-a-position"))
    }

    func test_custom_is_offered_only_when_it_is_already_the_selection() {
        let pinned = SpeakerSeparation.options(forValue: 0.65)
        XCTAssertEqual(pinned.map(\.value), ["distinct", "balanced", "merge"])

        let custom = SpeakerSeparation.options(forValue: 0.6)
        XCTAssertEqual(custom.map(\.value),
                       ["distinct", "balanced", "merge", SpeakerSeparation.customId])
        // The number is on the label because a segmented control has no second field
        // to reveal it in.
        XCTAssertEqual(custom.last?.label, "Custom (0.60)")
    }

    // MARK: - Clamp

    func test_clamp_holds_fluidaudios_range() {
        XCTAssertEqual(SpeakerSeparation.clamp(0.2), 0.5)
        XCTAssertEqual(SpeakerSeparation.clamp(2.0), 0.9)
        XCTAssertEqual(SpeakerSeparation.clamp(0.5), 0.5)
        XCTAssertEqual(SpeakerSeparation.clamp(0.9), 0.9)
        XCTAssertEqual(SpeakerSeparation.clamp(0.62), 0.62)
    }

    // MARK: - Cleanup toggle copy

    /// The clause is a promise about where a transcript goes. It is true only when the
    /// configured backend is one the regulated / NDA clamp would actually move.
    func test_nda_clause_appears_only_for_a_cloud_backend() {
        let nda = "regulated or NDA meeting runs it on this Mac instead"
        for id in ["anthropic", "auto", "claude_cli", "openai"] {
            XCTAssertTrue(DiarizeCleanup.sublabel(backendID: id).contains(nda),
                          "\(id) is clamped to local under NDA; the clause is true and useful")
        }
        for id in ["local", "apple_intelligence"] {
            XCTAssertFalse(DiarizeCleanup.sublabel(backendID: id).contains(nda),
                           "\(id) already runs on device; the clause would imply a cloud call")
        }
    }

    func test_on_device_backends_say_where_it_runs() {
        XCTAssertTrue(DiarizeCleanup.sublabel(backendID: "local")
            .contains("runs on this Mac, like your summaries"))
        // apple_intelligence summarizes in the daemon, but the cleanup pass runs in
        // Python, which collapses it to the local MLX backend.
        XCTAssertTrue(DiarizeCleanup.sublabel(backendID: "apple_intelligence")
            .contains("local MLX model"))
    }

    func test_an_unknown_backend_asserts_no_locality() {
        XCTAssertEqual(DiarizeCleanup.sublabel(backendID: "some_future_backend"),
                       DiarizeCleanup.base)
    }

    func test_every_shipped_backend_gets_the_cost_sentence() {
        for engine in SummarizationEngine.all {
            let text = DiarizeCleanup.sublabel(backendID: engine.id)
            XCTAssertTrue(text.hasPrefix(DiarizeCleanup.base),
                          "\(engine.id) must still say what the pass costs")
            // The apply step is the part a user gets wrong: Re-transcribe does not run
            // this pass (`mp finalize` skips it) and Re-summarize only redoes the summary.
            XCTAssertTrue(text.contains("neither Re-transcribe"))
        }
    }
}
