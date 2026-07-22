import XCTest
@testable import MeetingPipe

/// T3: the pure presentation derivation lifted out of `StatusBarController`.
/// The controller is the always-visible surface and had zero test references, so
/// every branch here is one the user sees and nothing checked.
final class StatusBarModelTests: XCTestCase {

    private typealias M = StatusBarModel

    private func source(_ name: String = "Zoom") -> AppSource {
        AppSource(bundleID: "us.zoom.xos", displayName: name, kind: .native, meetingTitle: nil)
    }

    private func recording(_ stem: String = "20260714-120000") -> AppState {
        .recording(
            file: URL(fileURLWithPath: "/tmp/\(stem).wav"),
            source: source(),
            summaryMode: .auto
        )
    }

    // MARK: - Title

    func test_idle_title() {
        XCTAssertEqual(M.title(.init(state: .idle)), " Idle")
    }

    func test_prompting_and_suppressed_name_the_app() {
        XCTAssertEqual(M.title(.init(state: .prompting(source: source()))), " Detected Zoom")
        XCTAssertEqual(M.title(.init(state: .suppressed(source: source()))), " Suppressed (Zoom)")
    }

    func test_recording_title_carries_mode_workflow_and_nda() {
        XCTAssertEqual(M.title(.init(state: recording())), " Recording")
        XCTAssertEqual(
            M.title(.init(state: recording(), summaryMode: .byo)), " Recording (BYO)"
        )
        XCTAssertEqual(
            M.title(.init(state: recording(), workflowName: "Client")), " Recording - Client"
        )
        XCTAssertEqual(
            M.title(.init(state: recording(), workflowName: "Client", ndaMode: true)),
            " Recording - Client · NDA"
        )
    }

    func test_stopping_title() {
        XCTAssertEqual(M.title(.init(state: .stopping(file: URL(fileURLWithPath: "/tmp/a.wav"),
                                                     source: source(), summaryMode: .auto))),
                       " Stopping…")
    }

    /// TECH-DSN7: one clause, not a pile-up. Background work replaces the base
    /// clause only while idle, and a download outranks the processing queue
    /// because it is what blocks summaries.
    func test_only_idle_shows_background_clauses_and_download_wins() {
        let downloading = ModelDownloadSupervisor.State.downloading(
            modelId: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            progress: 0.42, downloadedBytes: 1, totalBytes: 2
        )
        XCTAssertEqual(
            M.title(.init(state: .idle, processingCount: 3, download: downloading)), " ↓ 42%"
        )
        XCTAssertEqual(M.title(.init(state: .idle, processingCount: 3)), " Processing (3)")
        XCTAssertEqual(
            M.title(.init(state: recording(), processingCount: 3, download: downloading)),
            " Recording",
            "a recording title is never displaced by background work"
        )
    }

    func test_download_clause_shapes() {
        XCTAssertNil(M.downloadTitleClause(.idle))
        XCTAssertNil(M.downloadTitleClause(.completed(modelId: "a/b")))
        XCTAssertEqual(
            M.downloadTitleClause(.downloading(modelId: "a/b", progress: nil, downloadedBytes: 5, totalBytes: 0)),
            "↓ …",
            "an unknown total shows an ellipsis, not 0%"
        )
        XCTAssertEqual(M.downloadTitleClause(.failed(modelId: "a/b", error: "boom")), "↓ failed")
    }

    /// The regulated lock is a trailing glyph on top of whatever clause won, and
    /// it is suppressed by the UI setting rather than by the mode.
    func test_regulated_lock_is_a_glyph_not_a_clause() {
        XCTAssertEqual(
            M.title(.init(state: .idle, regulatedMode: true, showRegulatedBadge: true)),
            " Idle \u{1F512}"
        )
        XCTAssertEqual(
            M.title(.init(state: .idle, regulatedMode: true, showRegulatedBadge: false)), " Idle"
        )
        XCTAssertEqual(
            M.title(.init(state: .idle, processingCount: 2, regulatedMode: true, showRegulatedBadge: true)),
            " Processing (2) \u{1F512}"
        )
    }

    // MARK: - Icon

    func test_only_recording_wears_the_recording_icon() {
        XCTAssertEqual(M.icon(for: .idle), .idle)
        XCTAssertEqual(M.icon(for: .prompting(source: source())), .idle)
        XCTAssertEqual(M.icon(for: .suppressed(source: source())), .idle)
        XCTAssertEqual(M.icon(for: recording()), .recording)
        XCTAssertEqual(
            M.icon(for: .stopping(file: URL(fileURLWithPath: "/tmp/a.wav"), source: nil, summaryMode: .auto)),
            .idle,
            "the flush is not a recording"
        )
    }

    // MARK: - Menu header

    /// The header derives from the real state. It used to be fed `.idle` during
    /// a stop, so the menu read "Idle" while the title read "Stopping…" and the
    /// `.stopping` case was unreachable dead code.
    func test_header_label_covers_every_state() {
        XCTAssertEqual(M.headerLabel(.init(state: .idle)), "MeetingPipe: Idle")
        XCTAssertEqual(
            M.headerLabel(.init(state: .prompting(source: source()))), "MeetingPipe: Detected Zoom"
        )
        XCTAssertEqual(
            M.headerLabel(.init(state: .suppressed(source: source()))), "MeetingPipe: Suppressed (Zoom)"
        )
        XCTAssertEqual(M.headerLabel(.init(state: recording())), "MeetingPipe: Recording")
        XCTAssertEqual(
            M.headerLabel(.init(state: .stopping(file: URL(fileURLWithPath: "/tmp/a.wav"),
                                                 source: nil, summaryMode: .auto))),
            "MeetingPipe: Stopping…"
        )
    }

    /// The header shows processing alongside the state, unlike the title which
    /// replaces it. Two deliberately different rules.
    func test_header_appends_processing_in_every_state() {
        XCTAssertEqual(
            M.headerLabel(.init(state: .idle, processingCount: 2)),
            "MeetingPipe: Idle · Processing (2)"
        )
        XCTAssertEqual(
            M.headerLabel(.init(state: recording(), processingCount: 2)),
            "MeetingPipe: Recording · Processing (2)"
        )
    }

    // MARK: - Permissions

    func test_pending_permission_issue_matrix() {
        XCTAssertFalse(M.hasPendingPermissionIssue(.init()))
        // Mic counts notDetermined: an unprompted mic is a recording that fails.
        XCTAssertTrue(M.hasPendingPermissionIssue(.init(microphone: .notDetermined)))
        XCTAssertTrue(M.hasPendingPermissionIssue(.init(microphone: .denied)))
        XCTAssertTrue(M.hasPendingPermissionIssue(.init(screenRecording: .denied)))
        XCTAssertTrue(M.hasPendingPermissionIssue(.init(accessibility: .denied)))
        // The other two deliberately ignore the transient states so the row does
        // not flash at every cold launch.
        XCTAssertFalse(M.hasPendingPermissionIssue(.init(screenRecording: .notDetermined)))
        XCTAssertFalse(M.hasPendingPermissionIssue(.init(screenRecording: .unknown)))
        XCTAssertFalse(M.hasPendingPermissionIssue(.init(accessibility: .notDetermined)))
    }

    /// UX23: each missing permission names what stops working, and accessibility
    /// is deliberately not among them (it has its own `accessibilityDegraded` row).
    func test_permission_consequences_name_what_breaks() {
        XCTAssertEqual(M.permissionConsequences(.init()), [])
        XCTAssertEqual(
            M.permissionConsequences(.init(microphone: .denied)),
            ["⚠ Microphone off: recordings will be silent"]
        )
        // notDetermined is still a silent recording waiting to happen.
        XCTAssertEqual(
            M.permissionConsequences(.init(microphone: .notDetermined)),
            ["⚠ Microphone off: recordings will be silent"]
        )
        XCTAssertEqual(
            M.permissionConsequences(.init(screenRecording: .denied)),
            ["⚠ Screen Recording off: the call audio will not be recorded (mic only)"]
        )
        // The capture probe alone is authoritative even if the TCC read lags.
        XCTAssertEqual(
            M.permissionConsequences(.init(screenRecordingCaptureDenied: true)),
            ["⚠ Screen Recording off: the call audio will not be recorded (mic only)"]
        )
        XCTAssertEqual(M.permissionConsequences(.init(accessibility: .denied)), [])
        // Order is mic, then screen recording.
        XCTAssertEqual(
            M.permissionConsequences(.init(microphone: .denied, screenRecording: .denied)),
            [
                "⚠ Microphone off: recordings will be silent",
                "⚠ Screen Recording off: the call audio will not be recorded (mic only)",
            ]
        )
    }

    // MARK: - Rows

    func test_idle_menu_is_start_plus_quit() {
        XCTAssertEqual(M.rows(.init(state: .idle)), [.startRecording, .quitWithoutRelaunch])
    }

    func test_recording_menu_offers_stop_with_the_stem() {
        XCTAssertEqual(
            M.rows(.init(state: recording("20260714-093000"))),
            [.stopRecording(stem: "20260714-093000"), .quitWithoutRelaunch]
        )
    }

    /// Neither start nor stop while prompting or stopping: the transition is not
    /// something the menu can act on.
    func test_transient_states_offer_no_transport_row() {
        XCTAssertEqual(M.rows(.init(state: .prompting(source: source()))), [.quitWithoutRelaunch])
        XCTAssertEqual(
            M.rows(.init(state: .stopping(file: URL(fileURLWithPath: "/tmp/a.wav"),
                                          source: nil, summaryMode: .auto))),
            [.quitWithoutRelaunch]
        )
    }

    func test_quit_without_relaunch_is_hidden_when_auto_restart_is_off() {
        XCTAssertEqual(M.rows(.init(state: .idle, disableAutoRestart: true)), [.startRecording])
    }

    /// The Screen Recording deep link sits under the screen-recording consequence
    /// row. The capture probe's `.denied` is a separate signal from the
    /// `screenRecording` permission status, and on its own is authoritative enough
    /// to name the consequence and offer the link (UX23).
    func test_screen_recording_consequence_and_shortcut() {
        let srLine = "⚠ Screen Recording off: the call audio will not be recorded (mic only)"
        let denied = M.rows(.init(
            state: .idle, screenRecording: .denied, screenRecordingCaptureDenied: true
        ))
        XCTAssertEqual(
            denied,
            [.permissionConsequence(title: srLine), .screenRecordingShortcut, .startRecording, .quitWithoutRelaunch]
        )

        let captureOnly = M.rows(.init(state: .idle, screenRecordingCaptureDenied: true))
        XCTAssertEqual(
            captureOnly,
            [.permissionConsequence(title: srLine), .screenRecordingShortcut, .startRecording, .quitWithoutRelaunch]
        )
    }

    /// TECH-END4 (c): Accessibility keeps its own consequence row; it is not
    /// duplicated into the per-permission consequence list (UX23).
    func test_accessibility_denied_adds_its_own_row_only() {
        XCTAssertEqual(
            M.rows(.init(state: .idle, accessibility: .denied)),
            [.accessibilityDegraded, .startRecording, .quitWithoutRelaunch]
        )
    }

    func test_failed_meetings_row_pluralizes() {
        XCTAssertNil(M.failedMeetingsTitle(count: 0))
        XCTAssertEqual(
            M.failedMeetingsTitle(count: 1), "⚠ 1 meeting failed - open Library to retry"
        )
        XCTAssertEqual(
            M.failedMeetingsTitle(count: 4), "⚠ 4 meetings failed - open Library to retry"
        )
    }

    /// Row order is the decision, not just row presence: the download sits above
    /// the permission warnings, which sit above the failure row, which sits above
    /// the transport row.
    func test_full_row_order_under_everything_at_once() {
        let rows = M.rows(.init(
            state: .idle,
            download: .failed(modelId: "a/b", error: "boom"),
            microphone: .denied,
            accessibility: .denied,
            screenRecordingCaptureDenied: true,
            failedMeetingCount: 2
        ))
        XCTAssertEqual(rows, [
            .modelDownload(title: "⚠ Model download failed (b) - Retry", retryable: true, toolTip: "boom"),
            .permissionConsequence(title: "⚠ Microphone off: recordings will be silent"),
            .permissionConsequence(title: "⚠ Screen Recording off: the call audio will not be recorded (mic only)"),
            .screenRecordingShortcut,
            .accessibilityDegraded,
            .failedMeetings(count: 2, title: "⚠ 2 meetings failed - open Library to retry"),
            .startRecording,
            .quitWithoutRelaunch,
        ])
    }

    // MARK: - Download row

    func test_download_row_shapes() {
        XCTAssertNil(M.downloadRow(.idle))
        XCTAssertEqual(
            M.downloadRow(.completed(modelId: "mlx-community/Qwen2.5-7B-Instruct-4bit")),
            .modelDownload(title: "✓ Downloaded Qwen2.5-7B-Instruct-4bit", retryable: false, toolTip: nil)
        )
        XCTAssertEqual(
            M.downloadRow(.downloading(modelId: "a/b", progress: 0.5,
                                       downloadedBytes: 2_147_483_648, totalBytes: 4_294_967_296)),
            .modelDownload(title: "Downloading b: 2.0 GB / 4.0 GB (50%)", retryable: false, toolTip: nil)
        )
    }

    /// An unknown total is the resumable case: show what has landed rather than
    /// a fake denominator.
    func test_download_row_without_a_total() {
        XCTAssertEqual(
            M.downloadRow(.downloading(modelId: "a/b", progress: nil,
                                       downloadedBytes: 1_048_576, totalBytes: 0)),
            .modelDownload(title: "Downloading b: 1 MB downloaded", retryable: false, toolTip: nil)
        )
    }

    /// Only the failure row is clickable, and the full error goes to the tooltip
    /// so the row title stays short (LOCAL1).
    func test_only_a_failed_download_is_retryable() {
        for state in [
            ModelDownloadSupervisor.State.completed(modelId: "a/b"),
            .downloading(modelId: "a/b", progress: 0.1, downloadedBytes: 1, totalBytes: 10),
        ] {
            guard case .modelDownload(_, let retryable, let tip)? = M.downloadRow(state) else {
                return XCTFail("expected a row for \(state)")
            }
            XCTAssertFalse(retryable)
            XCTAssertNil(tip)
        }
    }

    func test_short_model_id_drops_the_org_prefix() {
        XCTAssertEqual(M.shortModelId("mlx-community/Qwen2.5-7B-Instruct-4bit"), "Qwen2.5-7B-Instruct-4bit")
        XCTAssertEqual(M.shortModelId("bare-name"), "bare-name")
        XCTAssertEqual(M.shortModelId("a/b/c"), "c")
    }

    func test_format_bytes_picks_a_unit() {
        XCTAssertEqual(M.formatBytes(512), "512 B")
        XCTAssertEqual(M.formatBytes(2048), "2 KB")
        XCTAssertEqual(M.formatBytes(5 * 1024 * 1024), "5 MB")
        XCTAssertEqual(M.formatBytes(3 * 1024 * 1024 * 1024), "3.0 GB")
    }
}
