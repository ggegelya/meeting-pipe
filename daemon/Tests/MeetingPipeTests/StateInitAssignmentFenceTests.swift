import Foundation
import XCTest

/// UX95: under SDK 27, `@State` is a macro, and Apple's notes ("@State as Macro") say a `@State`
/// declared with an initial value and assigned again in `init` keeps the declared value, so `body`
/// never sees what `init` passed. The fix is no default at the declaration and `init` as the one
/// assignment. This fence fails on any `@State` with an initializer whose name a
/// `_<name> = State(initialValue:` in the same file also assigns. Per file rather than per type,
/// which is stricter than the rule and costs nothing: no file holds two views that would collide.
final class StateInitAssignmentFenceTests: XCTestCase {
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Names of `@State` properties declared with an initial value, `= ...` on the declaration.
    static func defaultedStateNames(in code: String) -> Set<String> {
        let pattern = #"@State\s+(?:(?:private|fileprivate|internal|public)(?:\(set\))?\s+)*var\s+(\w+)\s*(?::[^=\n{]*)?="#
        return names(matching: pattern, in: code)
    }

    /// Names assigned in an init through `_<name> = State(initialValue:`.
    static func initAssignedStateNames(in code: String) -> Set<String> {
        names(matching: #"\b_(\w+)\s*=\s*State\(initialValue:"#, in: code)
    }

    private static func names(matching pattern: String, in code: String) -> Set<String> {
        let re = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        return Set(re.matches(in: code, range: range).compactMap {
            Range($0.range(at: 1), in: code).map { String(code[$0]) }
        })
    }

    func test_the_fence_reads_the_shapes_it_has_to_tell_apart() {
        let bad = "@State private var name: String = \"\"\ninit(n: String) { _name = State(initialValue: n) }"
        let good = "@State private var name: String\ninit(n: String) { _name = State(initialValue: n) }"
        let optional = "@State private var scope: String?\ninit() { _scope = State(initialValue: \"x\") }"
        let plain = "@State private var open = false"
        XCTAssertEqual(Self.defaultedStateNames(in: bad), ["name"])
        XCTAssertEqual(Self.defaultedStateNames(in: good), [])
        XCTAssertEqual(Self.defaultedStateNames(in: optional), [], "an optional with no `= nil` is the documented form")
        XCTAssertEqual(Self.defaultedStateNames(in: plain), ["open"])
        XCTAssertEqual(Self.initAssignedStateNames(in: bad), ["name"])
    }

    func test_no_defaulted_state_is_reassigned_in_an_init() throws {
        let root = repoRoot().appendingPathComponent("daemon/Sources")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var initAssigned = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            let code = String(SwiftSourceScan.codeOnly(try String(contentsOf: url, encoding: .utf8)))
            let assigned = Self.initAssignedStateNames(in: code)
            initAssigned += assigned.count
            for name in assigned.intersection(Self.defaultedStateNames(in: code)).sorted() {
                offenders.append("\(url.lastPathComponent): @State var \(name) has a default and is assigned in init")
            }
        }
        XCTAssertGreaterThanOrEqual(initAssigned, 5, "the init-assigned @State sites were not found; re-point this fence")
        XCTAssertEqual(offenders, [], "drop the declared default and keep init as the only assignment (UX95)")
    }
}
