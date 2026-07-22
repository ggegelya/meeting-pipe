import XCTest
@testable import MeetingPipe

/// Locks in the `DoctorCommand.execute` contract:
///   - Output marker per probe matches the documented format.
///   - Aggregate exit code: 0 unless at least one probe fails.
///   - `.warn` is informational and doesn't fail the run.
///
/// Each probe is injected as a canned `Probe` so the test doesn't drive
/// AX / AVFoundation / file system - those paths are exercised at
/// integration time via `MeetingPipe doctor` on a real machine.
final class DoctorCommandTests: XCTestCase {

    // MARK: - Output formatting

    func test_formatLine_renders_each_status_with_correct_marker() {
        let ok = DoctorCommand.ProbeResult(name: "x", status: .ok, message: "all good")
        XCTAssertEqual(DoctorCommand.formatLine(ok), "[ OK ] x: all good")

        let warn = DoctorCommand.ProbeResult(name: "x", status: .warn, message: "soft")
        XCTAssertEqual(DoctorCommand.formatLine(warn), "[WARN] x: soft")

        let fail = DoctorCommand.ProbeResult(name: "x", status: .fail, message: "broken")
        XCTAssertEqual(DoctorCommand.formatLine(fail), "[FAIL] x: broken")
    }

    // MARK: - Aggregate exit code

    private func probe(_ name: String, _ status: DoctorCommand.Status, _ msg: String = "") -> DoctorCommand.Probe {
        DoctorCommand.Probe(name: name) {
            DoctorCommand.ProbeResult(name: name, status: status, message: msg)
        }
    }

    func test_all_ok_exits_zero_and_prints_passed_summary() {
        var lines: [String] = []
        let code = DoctorCommand.execute(
            probes: [probe("a", .ok), probe("b", .ok)],
            writer: { lines.append($0) }
        )
        XCTAssertEqual(code, 0)
        XCTAssertTrue(lines.contains("doctor: all probes passed."))
    }

    func test_any_fail_exits_one_and_summary_counts_failures() {
        var lines: [String] = []
        let code = DoctorCommand.execute(
            probes: [probe("a", .ok), probe("b", .fail), probe("c", .fail)],
            writer: { lines.append($0) }
        )
        XCTAssertEqual(code, 1)
        XCTAssertTrue(lines.contains("doctor: 2 probes failed."))
    }

    func test_singular_summary_when_exactly_one_fails() {
        var lines: [String] = []
        let code = DoctorCommand.execute(
            probes: [probe("a", .fail)],
            writer: { lines.append($0) }
        )
        XCTAssertEqual(code, 1)
        XCTAssertTrue(lines.contains("doctor: 1 probe failed."))
    }

    func test_warn_does_not_count_as_failure() {
        var lines: [String] = []
        let code = DoctorCommand.execute(
            probes: [probe("a", .warn), probe("b", .warn), probe("c", .ok)],
            writer: { lines.append($0) }
        )
        XCTAssertEqual(code, 0, "WARN must not flip the exit code")
        XCTAssertTrue(lines.contains("doctor: all probes passed."))
    }

    // MARK: - Probe execution + ordering

    func test_each_probe_runs_exactly_once_in_input_order() {
        var calls: [String] = []
        let probes = ["one", "two", "three"].map { name in
            DoctorCommand.Probe(name: name) {
                calls.append(name)
                return DoctorCommand.ProbeResult(name: name, status: .ok, message: "")
            }
        }
        _ = DoctorCommand.execute(probes: probes, writer: { _ in })
        XCTAssertEqual(calls, ["one", "two", "three"])
    }

    // MARK: - Default probe set

    func test_defaultProbes_includes_every_documented_seam() {
        let names = DoctorCommand.defaultProbes().map { $0.name }
        XCTAssertTrue(names.contains("accessibility.trusted"))
        XCTAssertTrue(names.contains("permission.screen_recording"))
        XCTAssertTrue(names.contains("permission.microphone"))
        XCTAssertTrue(names.contains("pipeline.binary"))
        XCTAssertTrue(names.contains("pipeline.roundtrip"))
        XCTAssertTrue(names.contains("events.writable"))
        XCTAssertTrue(names.contains("search.index"))   // UX23
        // Every known meeting app gets an ax.app.<bundle> probe.
        for bundleID in DoctorCommand.knownMeetingBundleIDs {
            XCTAssertTrue(
                names.contains("ax.app.\(bundleID)"),
                "missing per-app probe for \(bundleID)"
            )
        }
    }

    /// UX23: the search-index probe is in the in-app doctor sheet's probe set too, not only the CLI.
    func test_daemonSelfCheckProbes_includes_search_index() {
        let names = DoctorCommand.daemonSelfCheckProbes().map { $0.name }
        XCTAssertTrue(names.contains("search.index"))
    }

    // MARK: - Per-probe pure helpers

    func test_probeAppReachable_warns_when_app_not_installed() {
        // A bundle ID that definitely isn't installed anywhere.
        let result = DoctorCommand.probeAppReachable(bundleID: "com.test.does-not-exist-anywhere-12345")
        XCTAssertEqual(result.status, .warn)
        XCTAssertEqual(result.name, "ax.app.com.test.does-not-exist-anywhere-12345")
    }
}
