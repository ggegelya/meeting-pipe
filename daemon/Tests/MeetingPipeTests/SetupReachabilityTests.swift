import XCTest
@testable import MeetingPipe

/// UX107: the Finish setup checklist and `mp doctor` read one reachability table.
/// `reachability-golden.json` is generated from `mp.reachability` (the table doctor
/// reads); each case is replayed here through the same mapping `Coordinator` uses, and
/// the checklist must name exactly the gaps doctor fails on.
final class SetupReachabilityTests: XCTestCase {

    private typealias C = SetupChecklist

    private func document() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "reachability-golden", withExtension: "json"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func sink(_ row: [String: String]) -> WorkflowSink? {
        switch row["type"] {
        case "notion": return .notion(databaseId: row["database_id"] ?? "")
        case "obsidian": return .obsidian
        case "filesystem": return .filesystem
        case "lan": return .lan
        default: return nil
        }
    }

    // MARK: - The table itself

    func test_backend_and_sink_needs_match_the_pipeline_table() throws {
        let contract = try XCTUnwrap(try document()["contract"] as? [String: Any])
        let backends = try XCTUnwrap(contract["backend_needs"] as? [String: [String]])
        let sinks = try XCTUnwrap(contract["sink_needs"] as? [String: [String]])
        XCTAssertEqual(Set(backends.keys), Set(WorkflowBackend.allCases.map(\.rawValue)))
        XCTAssertEqual(backends.mapValues { Set($0) }, C.backendNeeds.mapValues { Set($0.map(\.rawValue)) })
        XCTAssertEqual(sinks.mapValues { Set($0) }, C.sinkNeeds.mapValues { Set($0.map(\.rawValue)) })
        XCTAssertEqual(contract["gap_order"] as? [String], C.Gap.allCases.map(\.rawValue))
        XCTAssertEqual(contract["zero_egress_backend"] as? String, "local")
        XCTAssertEqual(contract["zero_egress_sinks"] as? [String], ["filesystem"])
        XCTAssertEqual(contract["claude_search_dirs"] as? [String], ClaudeBinaryLocator.searchDirs)
    }

    // MARK: - Agreement over the combinations

    func test_the_checklist_names_exactly_the_gaps_doctor_fails_on() throws {
        let cases = try XCTUnwrap(try document()["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        for row in cases {
            let name = try XCTUnwrap(row["name"] as? String)
            let present = try XCTUnwrap(row["present"] as? [String: Bool])
            let globalBackend = try XCTUnwrap(row["global_backend"] as? String)
            let globalDB = try XCTUnwrap(row["global_notion_database_id"] as? String)
            let workflows = try XCTUnwrap(row["workflows"] as? [[String: Any]]).map { wf in
                Workflow(
                    name: wf["name"] as? String ?? "",
                    sinks: (wf["sinks"] as? [[String: String]] ?? []).compactMap(sink),
                    backend: (wf["backend"] as? String).flatMap(WorkflowBackend.init(rawValue:)),
                    flags: WorkflowFlags(ndaMode: wf["nda"] as? Bool ?? false)
                )
            }
            let routes = C.workflowRoutes(workflows, globalBackend: globalBackend, globalNotionDatabaseId: globalDB)
            let items = C.decide(.init(
                regulatedMode: row["regulated"] as? Bool ?? false,
                globalBackend: globalBackend,
                globalSinks: row["global_sinks"] as? [String] ?? [],
                workflowBackends: routes.backends,
                workflowSinks: routes.sinks,
                anthropicKeyPresent: present["anthropic_key"] ?? false,
                openaiKeyPresent: present["openai_key"] ?? false,
                claudeBinaryPresent: present["claude_binary"] ?? false,
                notionTokenPresent: present["notion_token"] ?? false,
                notionDatabaseIdPresent: !globalDB.isEmpty,
                workflowNotionDatabasePresent: routes.notionDatabasePresent,
                localModelMissing: !(present["local_model"] ?? false)
            ))
            let named = items.reduce(into: Set<String>()) { $0.formUnion($1.gaps.map(\.rawValue)) }
            XCTAssertEqual(named, Set(row["gaps"] as? [String] ?? []), name)
            // A clean case shows no row at all.
            if (row["gaps"] as? [String])?.isEmpty == true {
                XCTAssertEqual(items, [], name)
            }
        }
    }

    // MARK: - The new items

    func test_openai_workflow_without_a_key_is_an_item() {
        let items = C.decide(.init(
            globalBackend: "anthropic",
            workflowBackends: ["anthropic", "openai"],
            workflowSinks: [["filesystem"], ["filesystem"]],
            openaiKeyPresent: false
        ))
        XCTAssertEqual(items, [.openaiKey])
        XCTAssertEqual(items.first?.title, "Add your OpenAI API key")
        XCTAssertEqual(items.first?.fix, .integrations)
    }

    func test_claude_cli_without_the_binary_is_an_item_that_opens_the_guide() {
        let items = C.decide(.init(
            globalBackend: "claude_cli",
            workflowBackends: ["claude_cli"],
            workflowSinks: [["filesystem"]],
            claudeBinaryPresent: false
        ))
        XCTAssertEqual(items, [.claudeBinary])
        XCTAssertEqual(items.first?.fix, .installClaudeCode)
    }

    func test_regulated_mode_needs_no_claude_binary_or_openai_key() {
        let items = C.decide(.init(
            regulatedMode: true,
            workflowBackends: ["claude_cli", "openai"],
            workflowSinks: [["notion"], ["notion"]],
            openaiKeyPresent: false,
            claudeBinaryPresent: false,
            notionTokenPresent: false,
            notionDatabaseIdPresent: false
        ))
        XCTAssertEqual(items, [])
    }

    func test_a_workflow_with_its_own_notion_database_does_not_ask_for_the_global_one() {
        let wf = Workflow(name: "Clients", sinks: [.notion(databaseId: "db-clients")])
        let routes = C.workflowRoutes([wf], globalBackend: "anthropic", globalNotionDatabaseId: "")
        let items = C.decide(.init(
            workflowBackends: routes.backends,
            workflowSinks: routes.sinks,
            notionDatabaseIdPresent: false,
            workflowNotionDatabasePresent: routes.notionDatabasePresent
        ))
        XCTAssertEqual(items, [])
    }

    func test_a_workflow_with_no_notion_database_and_no_global_one_asks() {
        let own = Workflow(name: "Clients", sinks: [.notion(databaseId: "db-clients")])
        let bare = Workflow(name: "Internal", sinks: [.notion(databaseId: "")])
        let routes = C.workflowRoutes([own, bare], globalBackend: "anthropic", globalNotionDatabaseId: "")
        let items = C.decide(.init(
            workflowBackends: routes.backends,
            workflowSinks: routes.sinks,
            notionDatabaseIdPresent: false,
            workflowNotionDatabasePresent: routes.notionDatabasePresent
        ))
        XCTAssertEqual(items, [.notion(needsToken: false, needsDatabase: true)])
    }

    // MARK: - The claude lookup

    func test_claude_is_found_in_a_fixed_dir_or_on_path_and_not_otherwise() {
        let home = NSString(string: "~/.local/bin/claude").expandingTildeInPath
        XCTAssertTrue(ClaudeBinaryLocator.isInstalled(environment: [:], isExecutable: { $0 == home }))
        XCTAssertTrue(ClaudeBinaryLocator.isInstalled(
            environment: ["PATH": "/nvm/bin:/usr/bin"], isExecutable: { $0 == "/nvm/bin/claude" }
        ))
        XCTAssertFalse(ClaudeBinaryLocator.isInstalled(environment: ["PATH": "/usr/bin"], isExecutable: { _ in false }))
    }

    /// The fix opens the Guide at a heading; the guide has to carry it.
    func test_the_guide_carries_the_install_claude_code_recipe() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let guide = try String(contentsOf: root.appendingPathComponent("docs/GUIDE.md"), encoding: .utf8)
        let heading = MainActor.assumeIsolated { GuideJumpRequest.installClaudeCode }
        XCTAssertTrue(guide.contains("\n### \(heading)\n"), "docs/GUIDE.md lost the heading Finish setup jumps to")
    }
}
