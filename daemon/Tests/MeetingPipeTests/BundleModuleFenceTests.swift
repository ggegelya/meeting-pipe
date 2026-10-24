import XCTest

/// DIST4: no source file reaches SwiftPM's `Bundle.module` except the two accessors that fall back to it outside an `.app`. Its generated accessor looks only at the `.app` root and an absolute path into `daemon/.build`, then `fatalError`s, so one stray `Bundle.module` (or `bundle: .module`) puts the installed app back into the launchd crash loop the moment the clone moves. `MeetingPipe doctor`'s `app.resources` probe only exercises the accessors; this is what covers every other call site. Reads the checkout, like `TutorialFenceTests`.
final class BundleModuleFenceTests: XCTestCase {

    /// The only files allowed to name `.module`, each exactly once, in its `?? .module` fallback.
    private static let accessors: Set<String> = [
        "daemon/Sources/MeetingPipe/AppResources.swift",
        "daemon/Sources/MeetingPipeCore/Infra/ResourceBundleLocator.swift",
    ]

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MeetingPipeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // daemon
            .deletingLastPathComponent()   // repo root
    }

    /// Every non-comment line in both source targets that names `.module`, as `path:line`.
    private func moduleReferences() throws -> [String: [Int]] {
        let root = repoRoot()
        let pattern = try NSRegularExpression(pattern: #"\.module\b"#)
        var found: [String: [Int]] = [:]
        var walked = 0
        for target in ["daemon/Sources/MeetingPipe", "daemon/Sources/MeetingPipeCore"] {
            let dir = root.appendingPathComponent(target)
            guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
                XCTFail("cannot walk \(target)")
                continue
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                walked += 1
                let path = url.path.replacingOccurrences(of: root.path + "/", with: "")
                let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                for (index, line) in lines.enumerated() {
                    if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                    let range = NSRange(line.startIndex..., in: line)
                    if pattern.firstMatch(in: line, range: range) != nil {
                        found[path, default: []].append(index + 1)
                    }
                }
            }
        }
        XCTAssertGreaterThan(walked, 100, "the walk found almost nothing; re-point this fence")
        return found
    }

    func test_no_source_file_reaches_bundle_module_outside_the_two_accessors() throws {
        let strays = try moduleReferences().filter { !Self.accessors.contains($0.key) }
        XCTAssertTrue(
            strays.isEmpty,
            "Bundle.module outside the DIST4 accessors (use Bundle.appResources / Bundle.coreResources): "
                + strays.map { "\($0.key):\($0.value.map(String.init).joined(separator: ","))" }.sorted().joined(separator: "; ")
        )
    }

    func test_each_accessor_names_module_exactly_once() throws {
        // Keeps the exemption honest: an accessor that grew a second `.module` is a stray too.
        let found = try moduleReferences()
        for accessor in Self.accessors {
            XCTAssertEqual(found[accessor]?.count, 1, "\(accessor) should name .module once, in its fallback")
        }
    }
}
