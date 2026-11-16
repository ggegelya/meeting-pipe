import XCTest
@testable import MeetingPipe

/// UX60. The point of these is the pairing, not the strings: the control's copy
/// and `mp.config.effective_backend`'s clamp were allowed to drift for months,
/// and the README additionally asserted the opposite of the code. So every
/// sentence that mentions the backend is asserted against `effectiveBackend`
/// rather than against a literal, in the shape `SpeakerAccuracyTests` uses.
final class RegulatedModeTests: XCTestCase {

    // MARK: - The sink rule, mirroring Python (SEC18)

    private struct SinkCase: Decodable {
        let configured: [String]
        let regulated: Bool
        let nda: Bool
        let expected: [String]
    }

    private func sink(_ name: String) -> WorkflowSink {
        switch name {
        case "notion": return .notion(databaseId: "")
        case "obsidian": return .obsidian
        case "filesystem": return .filesystem
        default: return .lan
        }
    }

    /// The table `pipeline/tests/test_zero_egress_files.py` runs `config.effective_sinks` and
    /// `workflow.apply_overrides` against: the same file, so the two trees cannot disagree.
    func testTheSinkRuleMatchesTheSharedTableWithPython() throws {
        struct Table: Decodable { let cases: [SinkCase] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sink-rule-golden.json")
        let table = try JSONDecoder().decode(Table.self, from: Data(contentsOf: url))
        XCTAssertFalse(table.cases.isEmpty)
        for c in table.cases {
            let got = RegulatedMode.effectiveSinks(
                configured: c.configured.map(sink), regulated: c.regulated, workflowNDA: c.nda
            ).map(\.typeName)
            XCTAssertEqual(got, c.expected, "configured=\(c.configured) regulated=\(c.regulated) nda=\(c.nda)")
        }
    }

    /// One Swift owner: the workflow and the privacy callout read the same rule.
    func testWorkflowAndPrivacyReachDelegateToTheOneRule() {
        let sinks: [WorkflowSink] = [.obsidian, .lan]
        XCTAssertEqual(PrivacyReach.reachableSinks(regulatedMode: true, workflowSinks: sinks), [.filesystem])
        XCTAssertEqual(PrivacyReach.reachableSinks(regulatedMode: false, workflowSinks: sinks), sinks)
    }

    /// G034: the copy names the sinks the rule takes away, built from the rule rather than beside it,
    /// so an Obsidian-only configuration is told its vault is skipped, not just Notion.
    func testTheCopyNamesEverySinkTheRuleDrops() {
        for engine in SummarizationEngine.all {
            for text in [RegulatedMode.footer(configured: engine.id), RegulatedMode.sublabel(isOn: true, configured: engine.id)] {
                XCTAssertTrue(text.contains("Obsidian"), text)
                XCTAssertTrue(text.contains("Notion"), text)
                XCTAssertTrue(text.contains("folder on this Mac"), text)
            }
        }
        XCTAssertEqual(RegulatedMode.droppedSinkNames, "Notion, Obsidian and the network share")
    }

    // MARK: - The clamp, mirroring Python

    func testRegulatedModeForcesLocalFromEveryCloudBackend() {
        for engine in SummarizationEngine.all where engine.id != "local" {
            XCTAssertEqual(
                RegulatedMode.effectiveBackend(configured: engine.id, regulated: true, workflowNDA: false),
                "local",
                "regulated mode must clamp \(engine.id) to local"
            )
        }
    }

    func testLocalBackendIsLeftAlone() {
        XCTAssertEqual(
            RegulatedMode.effectiveBackend(configured: "local", regulated: true, workflowNDA: false),
            "local"
        )
    }

    func testWorkflowNDAClampsOnItsOwn() {
        XCTAssertEqual(
            RegulatedMode.effectiveBackend(configured: "anthropic", regulated: false, workflowNDA: true),
            "local"
        )
    }

    func testNeitherFlagLeavesTheConfiguredBackend() {
        XCTAssertEqual(
            RegulatedMode.effectiveBackend(configured: "anthropic", regulated: false, workflowNDA: false),
            "anthropic"
        )
    }

    /// A backend id this build does not know still clamps. Python's rule is
    /// "anything that is not local", not a whitelist, and a fail-open here would
    /// be an egress hole rather than a cosmetic gap.
    func testUnknownBackendStillClamps() {
        XCTAssertEqual(
            RegulatedMode.effectiveBackend(configured: "some_future_vendor", regulated: true, workflowNDA: false),
            "local"
        )
        XCTAssertTrue(RegulatedMode.clampsBackend(configured: "some_future_vendor"))
    }

    func testClampsBackendIsFalseOnlyForLocal() {
        for engine in SummarizationEngine.all {
            XCTAssertEqual(
                RegulatedMode.clampsBackend(configured: engine.id),
                engine.id != "local",
                "clampsBackend disagreed with the clamp for \(engine.id)"
            )
        }
    }

    // MARK: - The copy cannot drift from the clamp

    /// The defect in one assertion: on a config the clamp moves, every string the
    /// user can read before flipping the switch has to say so.
    func testEveryStringNamesTheBackendClampWhenItApplies() {
        let clamped = SummarizationEngine.all.filter { RegulatedMode.clampsBackend(configured: $0.id) }
        XCTAssertFalse(clamped.isEmpty, "the fixture is empty, so the assertions below prove nothing")

        for engine in clamped {
            let onSublabel = RegulatedMode.sublabel(isOn: true, configured: engine.id)
            let offSublabel = RegulatedMode.sublabel(isOn: false, configured: engine.id)
            let footer = RegulatedMode.footer(configured: engine.id)

            XCTAssertTrue(
                onSublabel.contains(RegulatedMode.forcedEngine.name),
                "the on-state sublabel for \(engine.id) never names the engine that will run: \(onSublabel)"
            )
            XCTAssertTrue(
                footer.contains(RegulatedMode.forcedEngine.name),
                "the footer for \(engine.id) never names the engine that will run: \(footer)"
            )
            // The half the shipped copy had: Notion, in every register.
            XCTAssertTrue(onSublabel.contains("Notion"), onSublabel)
            XCTAssertTrue(offSublabel.contains("Notion"), offSublabel)
            XCTAssertTrue(footer.contains("Notion"), footer)
            // And the concrete comparison, which is what makes the clamp legible
            // to someone reading their own Preferences rather than the docs.
            XCTAssertTrue(
                onSublabel.contains(engine.name),
                "the on-state sublabel for \(engine.id) never names what it replaces: \(onSublabel)"
            )
        }
    }

    /// The mirror: on a config the clamp does NOT move, the copy must not claim a
    /// change. A warning that fires on everything is the failure mode a guard
    /// like this reaches for first.
    func testCopyClaimsNoBackendChangeWhenAlreadyLocal() {
        let onSublabel = RegulatedMode.sublabel(isOn: true, configured: "local")
        let footer = RegulatedMode.footer(configured: "local")

        XCTAssertTrue(onSublabel.contains("Notion"), onSublabel)
        XCTAssertTrue(footer.contains("Notion"), footer)
        XCTAssertFalse(
            onSublabel.contains("instead of"),
            "an already-local config is told something is being replaced: \(onSublabel)"
        )
        XCTAssertTrue(
            footer.contains("changes nothing about where they run"),
            "an already-local config should be told the clamp is a no-op for it: \(footer)"
        )
    }

    func testTitleNamesBothHalves() {
        XCTAssertTrue(RegulatedMode.title.contains("Notion"), RegulatedMode.title)
        XCTAssertTrue(
            RegulatedMode.title.lowercased().contains("on-device"),
            "the title still describes this as a Notion switch: \(RegulatedMode.title)"
        )
    }

    /// UX31's rule, applied here: no raw config id reaches the screen.
    func testNoCopyLeaksARawBackendID() {
        var strings = [RegulatedMode.title]
        for engine in SummarizationEngine.all {
            strings.append(RegulatedMode.sublabel(isOn: true, configured: engine.id))
            strings.append(RegulatedMode.sublabel(isOn: false, configured: engine.id))
            strings.append(RegulatedMode.footer(configured: engine.id))
            strings.append(
                RegulatedMode.modelMissingNotice(
                    isOn: true, configured: engine.id, modelIsMissing: true, downloadSize: "~4.3 GB"
                ) ?? ""
            )
        }
        for engine in SummarizationEngine.all {
            for s in strings {
                XCTAssertFalse(
                    s.contains(engine.id),
                    "raw config id '\(engine.id)' reached the screen in: \(s)"
                )
            }
        }
    }

    // MARK: - The model-missing notice

    func testModelMissingNoticeAppearsOnlyWhenOnAndMissingAndClamped() {
        XCTAssertNotNil(RegulatedMode.modelMissingNotice(
            isOn: true, configured: "anthropic", modelIsMissing: true, downloadSize: "~4.3 GB"
        ))
        // Off: the model is not needed, so the warning would be noise.
        XCTAssertNil(RegulatedMode.modelMissingNotice(
            isOn: false, configured: "anthropic", modelIsMissing: true, downloadSize: "~4.3 GB"
        ))
        // Present: nothing to say.
        XCTAssertNil(RegulatedMode.modelMissingNotice(
            isOn: true, configured: "anthropic", modelIsMissing: false, downloadSize: "~4.3 GB"
        ))
        // Already local: the model was needed before this toggle existed, so this
        // group is not where that gap is reported.
        XCTAssertNil(RegulatedMode.modelMissingNotice(
            isOn: true, configured: "local", modelIsMissing: true, downloadSize: "~4.3 GB"
        ))
    }

    func testModelMissingNoticeCarriesTheSizeAndRefusesTheCloudFallback() {
        let notice = RegulatedMode.modelMissingNotice(
            isOn: true, configured: "anthropic", modelIsMissing: true, downloadSize: "~4.3 GB"
        )
        XCTAssertEqual(notice?.contains("~4.3 GB"), true, notice ?? "nil")
        // The thing that surprises: it refuses rather than reaching for the cloud,
        // which is the whole point of the mode and the reason a missing model is
        // not a soft failure.
        XCTAssertEqual(notice?.contains("rather than fall back to the cloud"), true, notice ?? "nil")
    }

    func testNoEmDashesInAnyCopy() {
        var strings = [RegulatedMode.title]
        for engine in SummarizationEngine.all {
            strings.append(RegulatedMode.sublabel(isOn: true, configured: engine.id))
            strings.append(RegulatedMode.sublabel(isOn: false, configured: engine.id))
            strings.append(RegulatedMode.footer(configured: engine.id))
        }
        for s in strings {
            XCTAssertFalse(s.contains("\u{2014}"), "em-dash in: \(s)")
        }
    }
}
