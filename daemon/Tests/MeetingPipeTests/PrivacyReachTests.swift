import XCTest
@testable import MeetingPipe

/// DOC12 item 5. The point of the type is that the callout cannot name a vendor
/// the config does not use, so the tests are about *what the sentence omits* as
/// much as what it says: a Mac on OpenAI must not read "Anthropic", and a Mac
/// publishing to Obsidian must not read "Notion".
final class PrivacyReachTests: XCTestCase {

    // MARK: - Summarization half

    func test_cloud_backend_names_the_engine_it_actually_uses() {
        let s = PrivacyReach.summarizationSentence(configuredBackend: "openai", regulatedMode: false)
        XCTAssertTrue(s.contains("OpenAI"), s)
        XCTAssertFalse(s.contains("Anthropic"), "the old fixed string is what this exists to prevent: \(s)")
    }

    func test_claude_cli_is_named_too() {
        let s = PrivacyReach.summarizationSentence(configuredBackend: "claude_cli", regulatedMode: false)
        XCTAssertTrue(s.contains("Claude CLI"), s)
    }

    func test_on_device_backend_says_nothing_leaves() {
        let s = PrivacyReach.summarizationSentence(configuredBackend: "local", regulatedMode: false)
        XCTAssertTrue(s.contains("Local MLX"), s)
        XCTAssertTrue(s.contains("no transcript leaves this Mac"), s)
    }

    func test_apple_intelligence_is_on_device() {
        let s = PrivacyReach.summarizationSentence(configuredBackend: "apple_intelligence", regulatedMode: false)
        XCTAssertTrue(s.contains("Apple Intelligence"), s)
        XCTAssertTrue(s.contains("no transcript leaves this Mac"), s)
    }

    func test_auto_says_the_cloud_half_first() {
        let s = PrivacyReach.summarizationSentence(configuredBackend: "auto", regulatedMode: false)
        XCTAssertTrue(s.contains("Anthropic"), s)
        XCTAssertTrue(s.contains("Local MLX"), s)
    }

    /// The clamp, not a second copy of it: regulated mode pins every meeting to
    /// the on-device model, so the sentence has to follow `effectiveBackend`
    /// rather than the picker.
    func test_regulated_mode_moves_a_cloud_config_to_the_on_device_sentence() {
        let s = PrivacyReach.summarizationSentence(configuredBackend: "anthropic", regulatedMode: true)
        XCTAssertFalse(s.contains("Anthropic"), s)
        XCTAssertTrue(s.contains("Local MLX"), s)
        XCTAssertTrue(s.contains("no transcript leaves this Mac"), s)
    }

    func test_unknown_backend_points_at_the_control_rather_than_inventing_a_vendor() {
        let s = PrivacyReach.summarizationSentence(configuredBackend: "some_future_backend", regulatedMode: false)
        XCTAssertTrue(s.contains("Preferences"), s)
        XCTAssertFalse(s.contains("Anthropic"), s)
        XCTAssertFalse(s.contains("some_future_backend"), "a raw config id is not copy: \(s)")
    }

    // MARK: - Publish half

    func test_notion_is_named_when_a_workflow_publishes_there() {
        let s = PrivacyReach.publishSentence(regulatedMode: false, workflowSinks: [.notion(databaseId: "abc")])
        XCTAssertEqual(s, "Publishing sends it to Notion.")
    }

    func test_local_only_sinks_do_not_claim_a_network_reach() {
        let s = PrivacyReach.publishSentence(regulatedMode: false, workflowSinks: [.obsidian, .filesystem])
        XCTAssertEqual(s, "Publishing writes to this Mac only.")
        XCTAssertFalse(s.contains("Notion"), s)
    }

    func test_a_lan_share_counts_as_leaving_the_machine() {
        let s = PrivacyReach.publishSentence(regulatedMode: false, workflowSinks: [.lan])
        XCTAssertTrue(s.contains("network share"), s)
    }

    func test_mixed_sinks_name_the_off_machine_ones_and_account_for_the_rest() {
        let s = PrivacyReach.publishSentence(
            regulatedMode: false,
            workflowSinks: [.notion(databaseId: "abc"), .obsidian, .lan]
        )
        XCTAssertEqual(
            s,
            "Publishing sends it to Notion and the network share set in Integrations. Your other destinations write to this Mac."
        )
    }

    /// Two workflows on two Notion databases are one destination in a sentence
    /// about where data goes; `WorkflowSink.notion` carries the id, so plain
    /// sink dedupe would say "Notion and Notion".
    func test_two_notion_databases_read_as_one_destination() {
        let s = PrivacyReach.publishSentence(
            regulatedMode: false,
            workflowSinks: [.notion(databaseId: "one"), .notion(databaseId: "two")]
        )
        XCTAssertEqual(s, "Publishing sends it to Notion.")
    }

    func test_no_workflow_publishes_anywhere() {
        let s = PrivacyReach.publishSentence(regulatedMode: false, workflowSinks: [])
        XCTAssertTrue(s.contains("No workflow publishes anywhere"), s)
    }

    /// `mp.workflow.apply_overrides` rewrites `output.sinks` to `["filesystem"]`
    /// for any zero-egress run, whatever the editors hold. The callout has to
    /// report that, not the checkboxes.
    func test_regulated_mode_clamps_publishing_to_this_mac() {
        let s = PrivacyReach.publishSentence(
            regulatedMode: true,
            workflowSinks: [.notion(databaseId: "abc"), .lan]
        )
        XCTAssertEqual(s, "Publishing writes to this Mac only.")
        XCTAssertEqual(PrivacyReach.reachableSinks(regulatedMode: true, workflowSinks: [.notion(databaseId: "abc")]), [.filesystem])
    }

    // MARK: - The whole callout

    func test_the_shipped_default_reads_as_the_string_it_replaced_did() {
        let s = PrivacyReach.callout(
            configuredBackend: "anthropic",
            regulatedMode: false,
            sinks: [.notion(databaseId: "abc")]
        )
        XCTAssertEqual(
            s,
            "Audio capture and transcription are fully on-device. Summarizing sends the transcript to Anthropic. Publishing sends it to Notion."
        )
    }

    /// The configuration that made the old fixed string false end to end.
    func test_an_openai_plus_obsidian_mac_names_neither_old_vendor() {
        let s = PrivacyReach.callout(
            configuredBackend: "openai",
            regulatedMode: false,
            sinks: [.obsidian]
        )
        XCTAssertFalse(s.contains("Anthropic"), s)
        XCTAssertFalse(s.contains("Notion"), s)
        XCTAssertTrue(s.contains("OpenAI"), s)
    }

    func test_regulated_mode_reads_as_nothing_leaving() {
        let s = PrivacyReach.callout(
            configuredBackend: "anthropic",
            regulatedMode: true,
            sinks: [.notion(databaseId: "abc")]
        )
        XCTAssertFalse(s.contains("Anthropic"), s)
        XCTAssertFalse(s.contains("Notion"), s)
    }

    func test_no_em_dash_in_any_branch() {
        for backend in SummarizationEngine.all.map(\.id) + ["some_future_backend"] {
            for regulated in [true, false] {
                for sinks in [[], [.notion(databaseId: "d")], [.obsidian, .lan]] as [[WorkflowSink]] {
                    let s = PrivacyReach.callout(configuredBackend: backend, regulatedMode: regulated, sinks: sinks)
                    XCTAssertFalse(s.contains("\u{2014}"), s)
                }
            }
        }
    }
}
