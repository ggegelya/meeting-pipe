import XCTest

/// ARCH9: `ConfigStore` is the only Swift reader of `config.toml`. There used to be
/// five, each with its own parse and its own failure rule, and the two that read
/// regulated mode as false on a parse error kept the cloud tokens for a user whose
/// file said regulated. Source text is the fence, in the CI5 pattern: a new reader
/// is a line of code, and only a scan of the tree sees it before a user does.
final class ConfigStoreFenceTests: XCTestCase {

    /// Files allowed to parse TOML, each naming the file it reads. None is
    /// `config.toml`; the second test holds them to that.
    private let otherTOMLReaders: [String: String] = [
        "MeetingPipe/ConfigStore.swift": "config.toml, the one reader",
        "MeetingPipe/WorkflowStore.swift": "workflows.toml",
        "MeetingPipe/GlossaryStore.swift": "glossary.toml",
        "MeetingPipe/MeetingAppRegistry.swift": "the meeting-app registry",
        "MeetingPipeCore/MicGate/MuteLabelsLoader.swift": "the mute-label table",
    ]

    func test_only_known_files_parse_toml() throws {
        for (path, text) in try daemonSourceFiles() where text.contains("TOMLTable(string:") {
            XCTAssertNotNil(otherTOMLReaders[path],
                "\(path) parses TOML. If it reads config.toml, read a ConfigStore instead (ARCH9); "
                + "if it reads another file, add it to otherTOMLReaders naming that file.")
        }
    }

    func test_no_toml_parser_but_the_store_names_the_config_path() throws {
        let configPathSpellings = ["Config.defaultPath", "configRelative", "config.toml\""]
        for (path, text) in try daemonSourceFiles()
        where text.contains("TOMLTable(string:") && path != "MeetingPipe/ConfigStore.swift" {
            for spelling in configPathSpellings {
                XCTAssertFalse(text.contains(spelling),
                    "\(path) parses TOML and names the config path (\(spelling)); read a ConfigStore instead (ARCH9).")
            }
        }
    }

    func test_the_config_path_is_spelled_once() throws {
        // `appleContext` used to hard-code ".config/meeting-pipe/config.toml" beside
        // `Config.defaultPath`, so the two could drift and a test could not inject it.
        for (path, text) in try daemonSourceFiles() where path != "MeetingPipe/Endpoints.swift" {
            XCTAssertFalse(text.contains("meeting-pipe/config.toml\""),
                "\(path) spells the config path; use Config.defaultPath (ARCH9).")
        }
        for (path, text) in try daemonSourceFiles() where path != "MeetingPipe/Config.swift" {
            XCTAssertFalse(text.contains("Paths.configRelative"),
                "\(path) builds the config path itself; use Config.defaultPath (ARCH9).")
        }
    }

    func test_config_has_no_parser_of_its_own() throws {
        let config = try XCTUnwrap(try daemonSourceFiles().first { $0.0 == "MeetingPipe/Config.swift" }?.1)
        XCTAssertFalse(config.contains("TOMLKit"), "Config is produced by ConfigStore.config (ARCH9)")
        XCTAssertFalse(config.contains("static func load("), "Config is produced by ConfigStore.config (ARCH9)")
    }

    func test_the_fence_sees_the_tree() throws {
        // Guard the guard: a walker pointed at the wrong directory passes every test above.
        let files = try daemonSourceFiles()
        XCTAssertGreaterThan(files.count, 100)
        XCTAssertTrue(files.contains { $0.0 == "MeetingPipe/ConfigStore.swift" && $0.1.contains("TOMLTable(string:") })
    }

    private func daemonSourceFiles() throws -> [(String, String)] {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
            .appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(atPath: sources.path) else { return [] }
        var found: [(String, String)] = []
        for case let relative as String in walker where relative.hasSuffix(".swift") {
            let text = try String(contentsOf: sources.appendingPathComponent(relative), encoding: .utf8)
            found.append((relative, text))
        }
        return found
    }
}
