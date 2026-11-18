import Foundation
import XCTest

/// STOR9's per-store tests share three moves: plant a broken file, find the `.corrupt-` copy a
/// quarantine left, and make a file unreadable (chmod 000 on the file, not its directory).
enum StoreFiles {
    static let garbage = Data("{ this is not json".utf8)

    static func corruptCopies(of url: URL) -> [URL] {
        let dir = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".corrupt-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.map { dir.appendingPathComponent($0) }
    }

    /// Make `url` unreadable for the rest of the test; restored in a teardown block so cleanup works.
    static func lock(_ url: URL, in testCase: XCTestCase) {
        XCTAssertEqual(chmod(url.path, 0), 0)
        testCase.addTeardownBlock { chmod(url.path, 0o600) }
    }

    static func unlock(_ url: URL) {
        chmod(url.path, 0o600)
    }

    /// Wait until `predicate` holds, spinning the run loop (the JSON stores write on a private queue).
    static func waitUntil(_ predicate: () -> Bool, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return predicate()
    }
}
