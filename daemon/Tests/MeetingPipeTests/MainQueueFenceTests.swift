import XCTest
@testable import MeetingPipe

/// CONC6: the controller's main-queue rule is checked at runtime in debug builds, and the check cannot be
/// forgotten on a new method.
final class MainQueueFenceTests: XCTestCase {

    func test_the_predicate_is_false_off_main_and_true_on_main() {
        XCTAssertTrue(MainQueue.isCurrent)
        let off = expectation(description: "background")
        let seen = LockedBoolBox()
        DispatchQueue.global().async { seen.set(MainQueue.isCurrent); off.fulfill() }
        wait(for: [off], timeout: 5)
        XCTAssertFalse(seen.value)
        let on = expectation(description: "main queue")
        let seenMain = LockedBoolBox()
        DispatchQueue.main.async { seenMain.set(MainQueue.isCurrent); on.fulfill() }
        wait(for: [on], timeout: 5)
        XCTAssertTrue(seenMain.value)
    }

    /// Every non-private, non-static instance method of `MeetingSessionController` (and its extension
    /// files) opens with `assertMainQueue()`. A trapping precondition cannot be caught in-process, so this
    /// fences the call's presence instead.
    func test_every_non_private_controller_method_asserts_the_main_queue_first() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MeetingPipe")
        let files = try FileManager.default.contentsOfDirectory(atPath: sources.path)
            .filter { $0 == "MeetingSessionController.swift" || ($0.hasPrefix("MeetingSessionController+") && $0.hasSuffix(".swift")) }
        XCTAssertGreaterThanOrEqual(files.count, 3)
        var checked = 0
        var missing: [String] = []
        for file in files.sorted() {
            let lines = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8).components(separatedBy: "\n")
            var i = 0
            while i < lines.count {
                let l = lines[i]
                let isMethod = l.range(of: #"^    (@discardableResult\s+)?(nonisolated\s+)?func \w+"#, options: .regularExpression) != nil
                if isMethod {
                    var j = i, paren = 0
                    while true {
                        paren += lines[j].filter { $0 == "(" }.count - lines[j].filter { $0 == ")" }.count
                        if lines[j].trimmingCharacters(in: .whitespaces).hasSuffix("{"), paren <= 0 { break }
                        j += 1
                    }
                    checked += 1
                    if j + 1 >= lines.count || !lines[j + 1].contains("assertMainQueue()") {
                        missing.append("\(file):\(i + 1) \(l.trimmingCharacters(in: .whitespaces))")
                    }
                    i = j
                }
                i += 1
            }
        }
        XCTAssertGreaterThan(checked, 40, "the fence found too few methods to be reading the right files")
        XCTAssertTrue(missing.isEmpty, "methods that do not assert the main queue first:\n" + missing.joined(separator: "\n"))
    }
}

final class LockedBoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    func set(_ v: Bool) { lock.lock(); _value = v; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
}
