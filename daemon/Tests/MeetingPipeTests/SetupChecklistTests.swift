import XCTest
@testable import MeetingPipe

/// UX22: the pure "Finish setup" checklist derivation. Required-ness is
/// config-aware (an item shows only when relevant to the current config AND
/// unmet), so these lock the reachability branches the menu bar renders.
final class SetupChecklistTests: XCTestCase {

    private typealias C = SetupChecklist

    // MARK: - All green

    func test_all_green_shows_nothing() {
        // Everything configured, permissions granted, model cached.
        XCTAssertEqual(C.decide(.init()), [])
    }

    // MARK: - Fresh install (WorkflowMigrator seeded General: anthropic + notion)

    func test_fresh_install_shows_permissions_key_notion_not_model() {
        let items = C.decide(.init(
            globalBackend: "anthropic",
            globalSinks: ["notion"],
            workflowBackends: ["anthropic"],       // General inherits the global backend
            workflowSinks: [["notion"]],
            anthropicKeyPresent: false,
            notionTokenPresent: false,
            notionDatabaseIdPresent: false,
            localModelMissing: true,               // irrelevant: no local path
            hasPermissionIssue: true
        ))
        XCTAssertEqual(items, [
            .permissions,
            .anthropicKey,
            .notion(needsToken: true, needsDatabase: true),
        ])
    }

    // MARK: - Regulated mode forces local, suppresses cloud + notion

    func test_regulated_suppresses_key_and_notion_but_model_relevant() {
        let items = C.decide(.init(
            regulatedMode: true,
            globalBackend: "anthropic",            // overridden to local by regulated
            globalSinks: ["notion"],
            anthropicKeyPresent: false,
            notionTokenPresent: false,
            notionDatabaseIdPresent: false,
            localModelMissing: true
        ))
        XCTAssertEqual(items, [.localModel])
    }

    // MARK: - Local backend: only the model matters

    func test_local_backend_filesystem_shows_only_model() {
        let items = C.decide(.init(
            globalBackend: "local",
            workflowBackends: ["local"],
            workflowSinks: [["filesystem"]],
            anthropicKeyPresent: false,            // not relevant on local
            notionTokenPresent: false,             // not relevant: no notion sink
            notionDatabaseIdPresent: false,
            localModelMissing: true
        ))
        XCTAssertEqual(items, [.localModel])
    }

    // MARK: - Filesystem-only workflow is never nagged about Notion

    func test_filesystem_only_workflow_no_notion_item() {
        let items = C.decide(.init(
            globalBackend: "anthropic",
            globalSinks: ["notion"],               // global says notion, but a workflow overrides
            workflowBackends: ["anthropic"],
            workflowSinks: [["filesystem"]],
            anthropicKeyPresent: false,
            notionTokenPresent: false,
            notionDatabaseIdPresent: false
        ))
        // Cloud reachable -> key nagged; no active notion sink -> no notion item.
        XCTAssertEqual(items, [.anthropicKey])
    }

    // MARK: - Union across workflows (NDA preset alongside a cloud/notion one)

    func test_workflow_union_general_contributes_notion_and_key_nda_adds_model() {
        let items = C.decide(.init(
            globalBackend: "anthropic",
            workflowBackends: ["anthropic", "local"],  // General + NDA
            workflowSinks: [["notion"], ["filesystem"]],
            anthropicKeyPresent: false,
            notionTokenPresent: false,
            notionDatabaseIdPresent: false,
            localModelMissing: true
        ))
        XCTAssertEqual(items, [
            .anthropicKey,
            .notion(needsToken: true, needsDatabase: true),
            .localModel,
        ])
    }

    // MARK: - Apple Intelligence needs neither a cloud key nor an MLX model

    func test_apple_intelligence_backend_no_key_no_model() {
        let items = C.decide(.init(
            globalBackend: "apple_intelligence",
            workflowBackends: ["apple_intelligence"],
            workflowSinks: [["filesystem"]],
            anthropicKeyPresent: false,
            localModelMissing: true
        ))
        XCTAssertEqual(items, [])
    }

    // MARK: - Auto backend needs both a key (prefers cloud) and the model (fallback)

    func test_auto_backend_needs_key_and_model() {
        let items = C.decide(.init(
            globalBackend: "auto",
            workflowBackends: ["auto"],
            workflowSinks: [["filesystem"]],
            anthropicKeyPresent: false,
            localModelMissing: true
        ))
        XCTAssertEqual(items, [.anthropicKey, .localModel])
    }

    // MARK: - No workflows falls back to global config

    func test_no_workflows_uses_global_config() {
        let items = C.decide(.init(
            globalBackend: "anthropic",
            globalSinks: ["notion"],
            workflowBackends: [],
            workflowSinks: [],
            anthropicKeyPresent: false,
            notionTokenPresent: false,
            notionDatabaseIdPresent: false
        ))
        XCTAssertEqual(items, [
            .anthropicKey,
            .notion(needsToken: true, needsDatabase: true),
        ])
    }

    // MARK: - Notion partial (token present, database missing)

    func test_notion_needs_only_database() {
        let items = C.decide(.init(
            globalSinks: ["notion"],
            notionTokenPresent: true,
            notionDatabaseIdPresent: false
        ))
        XCTAssertEqual(items, [.notion(needsToken: false, needsDatabase: true)])
        XCTAssertEqual(items.first?.title, "Choose a Notion database")
    }

    // MARK: - Titles + parent label

    func test_item_titles() {
        XCTAssertEqual(C.Item.permissions.title, "Grant macOS permissions")
        XCTAssertEqual(C.Item.anthropicKey.title, "Add your Anthropic API key")
        XCTAssertEqual(C.Item.localModel.title, "Download the on-device model")
        XCTAssertEqual(C.Item.notion(needsToken: true, needsDatabase: true).title,
                       "Connect Notion (token + database)")
        XCTAssertEqual(C.Item.notion(needsToken: true, needsDatabase: false).title,
                       "Add your Notion token")
    }

    func test_item_fix_targets() {
        XCTAssertEqual(C.Item.permissions.fix, .permissions)
        XCTAssertEqual(C.Item.anthropicKey.fix, .integrations)
        XCTAssertEqual(C.Item.notion(needsToken: true, needsDatabase: true).fix, .integrations)
        XCTAssertEqual(C.Item.localModel.fix, .downloadModel)
    }

    func test_menu_title_pluralization() {
        XCTAssertNil(C.menuTitle(count: 0))
        XCTAssertEqual(C.menuTitle(count: 1), "Finish setup (1 step left)")
        XCTAssertEqual(C.menuTitle(count: 3), "Finish setup (3 steps left)")
    }
}
