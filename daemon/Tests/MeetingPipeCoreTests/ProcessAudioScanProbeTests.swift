import CoreAudio
import XCTest
@testable import MeetingPipeCore

/// DET12: the start-side, scan-scoped reader of `kAudioProcessPropertyIsRunningInput`.
///
/// The property itself and the matcher are `ProcessAudioSignal`'s and are pinned by
/// `ProcessAudioSignalTests`; what is new here is the cache's shape. It is the precondition for
/// wiring the read into the discovery scan at all, since resolution is a whole-list enumeration
/// plus per-object property reads and the scan has N candidates, so these count enumerations rather
/// than reason about them.
final class ProcessAudioScanProbeTests: XCTestCase {

    private let teams = "com.microsoft.teams2"
    private let zoom = "us.zoom.xos"

    /// The shape DET8 measured: Teams' media stack carries the detected app's bundle ID as a dotted
    /// prefix rather than the bundle ID itself, and splits audio across several helpers.
    private let liveList = ProcessAudioScanProbe.Snapshot(
        objects: [
            .init(objectID: 160, bundleID: "com.microsoft.teams2.modulehost", pid: 92432),
            .init(objectID: 161, bundleID: "com.microsoft.teams2.notificationcenter", pid: 92433),
            .init(objectID: 200, bundleID: "us.zoom.xos", pid: 700),
            .init(objectID: 300, bundleID: "com.apple.replayd", pid: 20286),
        ],
        status: noErr
    )

    private func probe(
        enumerations: @escaping () -> Void = {},
        snapshot: ProcessAudioScanProbe.Snapshot,
        running: Set<AudioObjectID>
    ) -> ProcessAudioScanProbe {
        ProcessAudioScanProbe(
            enumerator: { enumerations(); return snapshot },
            inputReader: { running.contains($0) },
            parentOf: { _ in nil }
        )
    }

    // MARK: - The cache

    func test_one_enumeration_serves_every_candidate_in_a_scan() {
        var count = 0
        let sut = probe(enumerations: { count += 1 }, snapshot: liveList, running: [160])

        sut.beginScan()
        XCTAssertEqual(sut.isRunningInput(bundleID: teams, pid: 92000), true)
        XCTAssertEqual(sut.isRunningInput(bundleID: zoom, pid: 700), false)
        XCTAssertEqual(count, 1)
    }

    func test_a_new_scan_re_enumerates() {
        // Not a long-lived cache. `ProcessAudioSignal` can hold one because a HAL list-change
        // listener tells it when to re-resolve; a synchronous scan has no listener, and DET8's probe
        // measured `replayd` taking a different object ID under the same PID nine minutes later.
        var count = 0
        let sut = probe(enumerations: { count += 1 }, snapshot: liveList, running: [160])

        sut.beginScan()
        _ = sut.isRunningInput(bundleID: teams, pid: 92000)
        sut.beginScan()
        _ = sut.isRunningInput(bundleID: teams, pid: 92000)
        XCTAssertEqual(count, 2)
    }

    func test_nothing_is_enumerated_until_the_first_read() {
        var count = 0
        let sut = probe(enumerations: { count += 1 }, snapshot: liveList, running: [])
        sut.beginScan()
        XCTAssertEqual(count, 0, "a scan with no candidate in the read set costs no HAL work")
    }

    // MARK: - What the reading means

    func test_input_is_ored_across_every_matched_object() {
        // Teams splits audio across ModuleHost and the WebView helpers and only ModuleHost read
        // input true in both of DET8's live calls, but which helper carries input is a Teams
        // implementation detail, so the OR is what keeps this correct across a Teams update.
        let sut = probe(snapshot: liveList, running: [161])
        XCTAssertEqual(sut.isRunningInput(bundleID: teams, pid: 92000), true)
    }

    func test_all_matched_objects_idle_reads_false() {
        let sut = probe(snapshot: liveList, running: [])
        XCTAssertEqual(sut.isRunningInput(bundleID: teams, pid: 92000), false)
    }

    func test_no_matching_object_is_unknown_rather_than_false() {
        // The distinction DET2 got wrong in the other direction: "the list holds nothing for this
        // app" is not "this app is not on the mic". The scanner degrades unknown to false for its
        // boolean tuple, but the probe must not make that call for it.
        let sut = probe(snapshot: liveList, running: [160])
        XCTAssertNil(sut.isRunningInput(bundleID: "com.tinyspeck.slackmacgap", pid: 400))
    }

    func test_a_failed_enumeration_is_unknown() {
        let failed = ProcessAudioScanProbe.Snapshot(objects: [], status: OSStatus(-4))
        let sut = probe(snapshot: failed, running: [160])
        XCTAssertNil(sut.isRunningInput(bundleID: teams, pid: 92000))
    }

    func test_an_unreadable_object_beside_a_readable_false_one_is_false() {
        // `reduceIsRunningInput`'s rule, reached through this seam: nil is reserved for "not one
        // object could be read", so a mix of one unreadable and one genuine false is false.
        let sut = ProcessAudioScanProbe(
            enumerator: { self.liveList },
            inputReader: { $0 == 160 ? nil : false },
            parentOf: { _ in nil }
        )
        XCTAssertEqual(sut.isRunningInput(bundleID: teams, pid: 92000), false)
    }

    func test_the_ancestry_fallback_still_applies() {
        // An app whose audio helper does not share its bundle ID resolves by PID ancestry, the
        // fallback `ProcessAudioSignal.match` owns. Pinned here because the scan probe passes its own
        // `parentOf` and a wiring mistake there would be silent.
        let helperOnly = ProcessAudioScanProbe.Snapshot(
            objects: [.init(objectID: 42, bundleID: "com.vendor.helper", pid: 5001)],
            status: noErr
        )
        let sut = ProcessAudioScanProbe(
            enumerator: { helperOnly },
            inputReader: { $0 == 42 },
            parentOf: { $0 == 5001 ? 5000 : nil }
        )
        XCTAssertEqual(sut.isRunningInput(bundleID: "com.vendor.app", pid: 5000), true)
    }
}
