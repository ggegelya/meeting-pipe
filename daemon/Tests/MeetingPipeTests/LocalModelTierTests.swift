import XCTest
@testable import MeetingPipe

/// LOCAL16: what this Mac can run, and what the preset picker says about it.
///
/// These rows are deliberately the same rows `pipeline/tests/test_resource_guard.py`
/// pins (16 / 24 / 32 / 48 GB against 3B / 7B / 14B). The two policies have to
/// agree, and there is no shared constant across the language boundary, so a
/// one-sided edit is meant to fail one of the two suites.
final class LocalModelTierTests: XCTestCase {

    private let small = "mlx-community/Qwen2.5-3B-Instruct-4bit"
    private let recommended = "mlx-community/Qwen2.5-7B-Instruct-4bit"
    private let large = "mlx-community/Qwen2.5-14B-Instruct-4bit"
    private let custom = "mlx-community/some-instruct-4bit"

    // MARK: - The size estimate

    func test_estimated_size_parses_the_parameter_count() {
        XCTAssertEqual(LocalModelTier.estimatedModelGB(small), 1.9)
        XCTAssertEqual(LocalModelTier.estimatedModelGB(recommended), 4.3)
        XCTAssertEqual(LocalModelTier.estimatedModelGB(large), 8.7)
        XCTAssertEqual(LocalModelTier.estimatedModelGB("mlx-community/Qwen2.5-32B-Instruct-4bit"), 19.8)
    }

    func test_the_quant_suffix_is_not_a_parameter_count() {
        // "4bit" read as 4B would size a 3B model at 2.5 GB and let a 14B through
        // on a machine that cannot hold it.
        XCTAssertNil(LocalModelTier.estimatedModelGB(custom))
    }

    // MARK: - The tier table

    func test_sixteen_gb_runs_the_default_and_refuses_the_large() {
        // LOCAL6 recorded the 14B as "can OOM on 16 GB"; the 7B is the shipped
        // default and runs, with little headroom rather than comfortably.
        XCTAssertEqual(LocalModelTier.fit(modelId: small, ramGB: 16), .fits)
        XCTAssertEqual(LocalModelTier.fit(modelId: recommended, ramGB: 16), .tight)
        XCTAssertEqual(LocalModelTier.fit(modelId: large, ramGB: 16), .over)
    }

    func test_twenty_four_gb_is_the_large_models_floor() {
        XCTAssertEqual(LocalModelTier.fit(modelId: recommended, ramGB: 24), .fits)
        XCTAssertEqual(LocalModelTier.fit(modelId: large, ramGB: 24), .tight)
    }

    func test_thirty_two_gb_still_calls_the_large_tight() {
        // The owner's Mac. The 14B runs here and has still OOM-hung it at long
        // context, so "comfortable" would be a lie the machine has disproved.
        XCTAssertEqual(LocalModelTier.fit(modelId: recommended, ramGB: 32), .fits)
        XCTAssertEqual(LocalModelTier.fit(modelId: large, ramGB: 32), .tight)
    }

    func test_forty_eight_gb_is_the_first_roomy_tier_for_the_large() {
        XCTAssertEqual(LocalModelTier.fit(modelId: large, ramGB: 48), .fits)
    }

    func test_an_unsized_model_is_never_refused() {
        // The Custom preset is the user's one escape hatch; the pipeline's
        // free-RAM watchdog is what covers a model nobody can size.
        XCTAssertEqual(LocalModelTier.fit(modelId: custom, ramGB: 8), .unknown)
        XCTAssertTrue(LocalModelTier.isRunnable(modelId: custom, ramGB: 8))
    }

    func test_a_machine_below_the_first_tier_still_gets_a_policy() {
        XCTAssertEqual(LocalModelTier.tier(forRamGB: 4), LocalModelTier.tiers[0])
    }

    func test_context_ceilings_never_shrink_as_the_machine_grows() {
        let ceilings = [8.0, 16, 24, 32, 48, 128].map {
            LocalModelTier.tier(forRamGB: $0).contextTokenCeiling
        }
        XCTAssertEqual(ceilings, ceilings.sorted())
        XCTAssertEqual(LocalModelTier.tier(forRamGB: 32).contextTokenCeiling, 8_000)
    }

    // MARK: - What the picker says

    func test_annotation_states_the_machine_in_front_of_the_user() {
        XCTAssertEqual(
            LocalModelTier.annotation(modelId: large, ramGB: 16),
            "Needs about 24 GB; this Mac has 16 GB."
        )
        XCTAssertTrue(
            LocalModelTier.annotation(modelId: recommended, ramGB: 32).contains("Fits comfortably")
        )
        XCTAssertTrue(
            LocalModelTier.annotation(modelId: large, ramGB: 32).contains("little headroom")
        )
    }

    func test_the_over_tier_row_carries_its_reason_not_just_a_gray_label() {
        // UX30's truthful-disabled rule: a disabled control has to say why.
        let row = LocalModelTier.rowLabel("Large (Qwen 14B-4bit)", modelId: large, ramGB: 16)
        XCTAssertTrue(row.hasPrefix("Large (Qwen 14B-4bit)"))
        XCTAssertTrue(row.contains("Needs about 24 GB"))
        XCTAssertTrue(row.contains("this Mac has 16 GB"))
    }

    func test_a_runnable_row_is_just_its_label() {
        XCTAssertEqual(
            LocalModelTier.rowLabel("Recommended (Qwen 7B-4bit)", modelId: recommended, ramGB: 32),
            "Recommended (Qwen 7B-4bit)"
        )
    }

    func test_ram_reads_whole_when_it_is_whole() {
        // "this Mac has 16.0 GB" is the kind of detail that makes a UI look
        // machine-generated rather than considered.
        XCTAssertFalse(LocalModelTier.annotation(modelId: large, ramGB: 16).contains("16.0"))
    }

    func test_every_shipped_preset_is_sized() {
        // A preset the tier policy cannot size would silently opt out of the
        // whole guard, which is the failure mode that is hardest to notice.
        for preset in LocalModelPreset.all {
            XCTAssertNotNil(
                LocalModelTier.estimatedModelGB(preset.modelId),
                "preset \(preset.id) has no parsable parameter count"
            )
        }
    }

    func test_the_machine_reports_some_memory() {
        XCTAssertGreaterThan(LocalModelTier.physicalRamGB(), 0)
    }
}
