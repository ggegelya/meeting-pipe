import XCTest
@testable import MeetingPipe

/// `KeychainBackend` with an injected runner, so nothing here launches `security` (SEC23).
final class KeychainBackendTests: XCTestCase {

    private final class Recorder {
        var calls: [(args: [String], stdin: String?)] = []
        var result: KeychainBackend.Output? = (0, "", "")
        func runner() -> KeychainBackend.Runner {
            { [self] args, stdin in
                calls.append((args, stdin.flatMap { String(data: $0, encoding: .utf8) }))
                return result
            }
        }
    }

    func test_set_sends_the_secret_on_stdin_and_never_in_argv() throws {
        let rec = Recorder()
        let backend = KeychainBackend(service: "svc", runner: rec.runner())
        try backend.set("sk-ant-SECRET", for: "ANTHROPIC_API_KEY")
        XCTAssertEqual(rec.calls.count, 1)
        XCTAssertEqual(rec.calls[0].args, ["-i"])
        XCTAssertEqual(rec.calls[0].stdin, "add-generic-password -U -s \"svc\" -a \"ANTHROPIC_API_KEY\" -w \"sk-ant-SECRET\"\n")
        XCTAssertFalse(rec.calls[0].args.joined().contains("SECRET"))
    }

    func test_set_escapes_backslash_and_double_quote_only() throws {
        let rec = Recorder()
        let backend = KeychainBackend(service: "svc", runner: rec.runner())
        try backend.set("a b\"c$d\\e'f", for: "NOTION_TOKEN")
        XCTAssertEqual(rec.calls[0].stdin, "add-generic-password -U -s \"svc\" -a \"NOTION_TOKEN\" -w \"a b\\\"c$d\\\\e'f\"\n")
    }

    func test_set_refuses_a_value_it_cannot_quote_without_running_security() {
        for bad in ["two\nlines", "tab\there", "nul\u{0}byte", "caf\u{e9}", "del\u{7f}", ""] {
            let rec = Recorder()
            let backend = KeychainBackend(service: "svc", runner: rec.runner())
            XCTAssertThrowsError(try backend.set(bad, for: "NOTION_TOKEN"), "value \(bad.debugDescription)") { error in
                guard case KeychainBackend.KeychainError.unquotable = error else {
                    return XCTFail("expected unquotable, got \(error)")
                }
            }
            XCTAssertTrue(rec.calls.isEmpty, "security must not run for \(bad.debugDescription)")
        }
    }

    func test_set_throws_on_a_failed_run() {
        let rec = Recorder()
        rec.result = (1, "", "denied")
        XCTAssertThrowsError(try KeychainBackend(service: "svc", runner: rec.runner()).set("x", for: "NOTION_TOKEN"))
        rec.result = nil
        XCTAssertThrowsError(try KeychainBackend(service: "svc", runner: rec.runner()).set("x", for: "NOTION_TOKEN"))
    }

    func test_value_maps_status_to_a_typed_read() {
        let rec = Recorder()
        let backend = KeychainBackend(service: "svc", runner: rec.runner())
        rec.result = (0, "sk-x\n", "")
        XCTAssertEqual(backend.value(for: "A"), .found("sk-x"))
        XCTAssertEqual(rec.calls[0].args, ["find-generic-password", "-s", "svc", "-a", "A", "-w"])
        rec.result = (0, "\n", "")
        XCTAssertEqual(backend.value(for: "A"), .notFound)
        rec.result = (44, "", "could not be found")
        XCTAssertEqual(backend.value(for: "A"), .notFound)
        rec.result = (51, "", "interaction not allowed")
        XCTAssertEqual(backend.value(for: "A"), .unreadable(status: 51, detail: "interaction not allowed"))
        rec.result = (36, "", "")
        guard case .unreadable(let status, _) = backend.value(for: "A") else { return XCTFail("36 must be unreadable") }
        XCTAssertEqual(status, 36)
        rec.result = nil
        XCTAssertEqual(backend.value(for: "A"), .unreadable(status: -1, detail: "security not runnable"))
    }

    func test_remove_treats_absent_as_removed_and_other_failures_as_errors() throws {
        let rec = Recorder()
        let backend = KeychainBackend(service: "svc", runner: rec.runner())
        try backend.remove("A")
        XCTAssertEqual(rec.calls[0].args, ["delete-generic-password", "-s", "svc", "-a", "A"])
        rec.result = (44, "", "not found")
        XCTAssertNoThrow(try backend.remove("A"))
        rec.result = (36, "", "locked")
        XCTAssertThrowsError(try backend.remove("A"))
        rec.result = nil
        XCTAssertThrowsError(try backend.remove("A"))
    }

    // MARK: - The real process path, against stand-ins for `security`

    func test_run_feeds_stdin_and_reads_stdout() throws {
        let out = try XCTUnwrap(KeychainBackend.run(executable: "/bin/cat", args: [], stdin: Data("hello\n".utf8), timeout: 5))
        XCTAssertEqual(out.status, 0)
        XCTAssertEqual(out.stdout, "hello\n")
    }

    func test_run_survives_a_child_that_exits_without_reading_stdin() throws {
        // A closed read end must fail the write with EPIPE, not deliver the daemon a SIGPIPE.
        for _ in 0..<20 {
            let out = try XCTUnwrap(KeychainBackend.run(executable: "/usr/bin/true", args: [], stdin: Data(repeating: 65, count: 4096), timeout: 5))
            XCTAssertEqual(out.status, 0)
        }
    }

    func test_run_gives_up_on_a_child_that_never_answers() {
        let started = Date()
        XCTAssertNil(KeychainBackend.run(executable: "/bin/sleep", args: ["30"], stdin: nil, timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
