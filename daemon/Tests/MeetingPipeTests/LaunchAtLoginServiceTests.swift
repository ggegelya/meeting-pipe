import os
import XCTest
@testable import MeetingPipe

/// UX42: the launch-at-login state machine, driven entirely through the injected
/// launchctl runner. The point of the seam is that none of this touches the real
/// `com.meetingpipe.daemon` service, so running the suite can never change
/// whether the developer's own Mac starts MeetingPipe at the next login.
final class LaunchAtLoginServiceTests: XCTestCase {

    // MARK: - Fake

    /// UX67 made `LaunchctlRunning` `Sendable`, because the service now crosses to
    /// a detached task. The state moves under a lock rather than behind an
    /// `@unchecked Sendable`, which `daemon/CLAUDE.md` caps at the two that exist.
    private final class FakeLaunchctl: LaunchctlRunning {
        private struct State {
            var invocations: [[String]] = []
            var responses: [String: LaunchctlResult] = [:]
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        init(printDisabled: String = "") {
            state.withLock { $0.responses["print-disabled"] = LaunchctlResult(status: 0, output: printDisabled) }
        }

        /// Canned results keyed by subcommand (`print-disabled`, `enable`, ...).
        var responses: [String: LaunchctlResult] {
            get { state.withLock { $0.responses } }
            set { state.withLock { $0.responses = newValue } }
        }

        /// Every argv the service handed to launchctl, in order.
        var invocations: [[String]] { state.withLock { $0.invocations } }

        func run(_ arguments: [String]) -> LaunchctlResult {
            state.withLock { s in
                s.invocations.append(arguments)
                return s.responses[arguments.first ?? ""] ?? LaunchctlResult(status: 0, output: "")
            }
        }

        var verbs: [String] { invocations.compactMap(\.first) }
        func argv(_ verb: String) -> [String]? { invocations.first { $0.first == verb } }
        func count(_ verb: String) -> Int { verbs.filter { $0 == verb }.count }
    }

    private let target = "gui/501/com.meetingpipe.daemon"
    private let plist = "/tmp/mp-test/com.meetingpipe.daemon.plist"

    private func service(
        _ runner: FakeLaunchctl, plistExists: Bool = true
    ) -> LaunchAtLoginService {
        LaunchAtLoginService(
            runner: runner, uid: 501, plistPath: plist, plistExists: { _ in plistExists }
        )
    }

    /// The real shape of `launchctl print-disabled gui/<uid>`, trimmed.
    private func printDisabled(_ verdict: String) -> String {
        """
        disabled services = {
        \t\t"com.docker.helper" => enabled
        \t\t"com.meetingpipe.daemon" => \(verdict)
        \t\t"com.apple.Siri.agent" => disabled
        }
        """
    }

    private let noOverride = """
        disabled services = {
        \t\t"com.docker.helper" => enabled
        }
        """

    // MARK: - Reads reflect launchd, not a preference

    func test_a_disabled_override_reads_as_disabled() {
        let runner = FakeLaunchctl(printDisabled: printDisabled("disabled"))
        let status = service(runner).status()
        XCTAssertEqual(status.state, .disabled)
        XCTAssertNil(status.error)
        XCTAssertFalse(status.isOn)
        XCTAssertEqual(runner.argv("print-disabled"), ["print-disabled", "gui/501"])
    }

    func test_an_enabled_override_reads_as_enabled() {
        let status = service(FakeLaunchctl(printDisabled: printDisabled("enabled"))).status()
        XCTAssertEqual(status.state, .enabled)
        XCTAssertTrue(status.isOn)
    }

    func test_no_override_line_at_all_reads_as_enabled() {
        // launchd treats a missing override as "use the plist", and the plist
        // carries RunAtLoad=true. Reading absence as off would make a fresh
        // install's toggle claim the app does not start when it does.
        XCTAssertEqual(service(FakeLaunchctl(printDisabled: noOverride)).status().state, .enabled)
    }

    func test_a_missing_plist_reads_as_not_installed_without_calling_launchctl() {
        let runner = FakeLaunchctl()
        let status = service(runner, plistExists: false).status()
        XCTAssertEqual(status.state, .notInstalled)
        XCTAssertNil(status.error)
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func test_an_unreadable_state_says_the_switch_may_not_match() {
        let runner = FakeLaunchctl()
        runner.responses["print-disabled"] = LaunchctlResult(status: 1, output: "Bad request")
        let status = service(runner).status()
        XCTAssertEqual(status.state, .enabled, "fall back to the plist's own RunAtLoad")
        let error = status.error ?? ""
        XCTAssertTrue(error.contains("Could not read whether MeetingPipe starts at login"), error)
        XCTAssertTrue(error.contains("may not match"), "an unread state must not be presented as a confident one: \(error)")
    }

    // MARK: - Turning it on

    func test_on_enables_then_bootstraps_when_the_job_is_not_loaded() {
        let runner = FakeLaunchctl(printDisabled: printDisabled("disabled"))
        runner.responses["print"] = LaunchctlResult(status: 113, output: "Could not find service")

        let status = service(runner).set(enabled: true)

        XCTAssertEqual(status.state, .enabled)
        XCTAssertNil(status.error)
        XCTAssertEqual(runner.argv("enable"), ["enable", target])
        XCTAssertEqual(runner.argv("bootstrap"), ["bootstrap", "gui/501", plist])
        let verbs = runner.verbs
        guard let enabledAt = verbs.firstIndex(of: "enable"),
              let bootstrappedAt = verbs.firstIndex(of: "bootstrap") else {
            return XCTFail("expected both an enable and a bootstrap, got \(verbs)")
        }
        XCTAssertLessThan(enabledAt, bootstrappedAt,
                          "bootstrapping a still-disabled service fails, so enable has to come first")
    }

    func test_on_does_not_bootstrap_a_job_that_is_already_loaded() {
        let runner = FakeLaunchctl(printDisabled: printDisabled("disabled"))
        runner.responses["print"] = LaunchctlResult(status: 0, output: "state = running")

        XCTAssertEqual(service(runner).set(enabled: true).state, .enabled)
        XCTAssertFalse(runner.verbs.contains("bootstrap"))
    }

    func test_on_without_a_plist_surfaces_an_error_and_calls_nothing() {
        let runner = FakeLaunchctl()
        let status = service(runner, plistExists: false).set(enabled: true)
        XCTAssertEqual(status.state, .notInstalled)
        XCTAssertEqual(status.error?.contains("scripts/install.sh"), true)
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    // MARK: - Turning it off

    func test_off_disables_and_never_boots_out() {
        let runner = FakeLaunchctl(printDisabled: printDisabled("enabled"))

        let status = service(runner).set(enabled: false)

        XCTAssertEqual(status.state, .disabled)
        XCTAssertNil(status.error)
        XCTAssertEqual(runner.argv("disable"), ["disable", target])
        // Booting out the agent that owns the running process would kill the app
        // under the user's pointer. This is the whole reason off is `disable`.
        XCTAssertFalse(runner.verbs.contains("bootout"))
        XCTAssertFalse(runner.verbs.contains("unload"))
        XCTAssertFalse(runner.verbs.contains("kickstart"))
    }

    func test_neither_direction_ever_uses_a_destructive_verb() {
        let destructive: Set<String> = ["bootout", "unload", "kill", "kickstart", "remove"]
        for wanted in [true, false] {
            let runner = FakeLaunchctl(printDisabled: printDisabled("disabled"))
            runner.responses["print"] = LaunchctlResult(status: 113, output: "")
            service(runner).set(enabled: wanted)
            XCTAssertTrue(
                Set(runner.verbs).isDisjoint(with: destructive),
                "set(enabled: \(wanted)) used \(Set(runner.verbs).intersection(destructive))"
            )
        }
    }

    // MARK: - Failures reach the user

    func test_a_refused_disable_surfaces_a_user_visible_error() {
        let runner = FakeLaunchctl(printDisabled: printDisabled("enabled"))
        runner.responses["disable"] = LaunchctlResult(status: 5, output: "Input/output error")

        let status = service(runner).set(enabled: false)

        let error = status.error ?? ""
        XCTAssertTrue(error.contains("Could not turn launch at login off"), error)
        XCTAssertTrue(error.contains("5"), "the exit status is the actionable half: \(error)")
        XCTAssertTrue(error.contains("Input/output error"), error)
        XCTAssertEqual(status.state, .enabled,
                       "a refused write leaves launchd as it was, so re-read rather than assume")
    }

    func test_a_refused_enable_surfaces_an_error_and_does_not_bootstrap() {
        let runner = FakeLaunchctl(printDisabled: printDisabled("disabled"))
        runner.responses["enable"] = LaunchctlResult(status: 5, output: "Input/output error")

        let status = service(runner).set(enabled: true)

        XCTAssertEqual(status.error?.contains("Could not turn launch at login on"), true)
        XCTAssertEqual(status.state, .disabled, "the read-back, not the request")
        XCTAssertFalse(runner.verbs.contains("bootstrap"))
    }

    func test_a_refused_bootstrap_still_reports_the_override_cleared() {
        let runner = FakeLaunchctl(printDisabled: printDisabled("disabled"))
        runner.responses["print"] = LaunchctlResult(status: 113, output: "")
        runner.responses["bootstrap"] = LaunchctlResult(status: 5, output: "Input/output error")

        let status = service(runner).set(enabled: true)

        XCTAssertEqual(status.state, .enabled, "enable succeeded, so the next login will start it")
        XCTAssertEqual(status.error?.contains("Could not load the MeetingPipe launch agent"), true)
    }

    // MARK: - The parser

    func test_parser_reads_both_verdicts_and_absence() {
        XCTAssertEqual(
            LaunchAtLoginService.parseDisabled(printDisabled("disabled"), label: "com.meetingpipe.daemon"),
            true)
        XCTAssertEqual(
            LaunchAtLoginService.parseDisabled(printDisabled("enabled"), label: "com.meetingpipe.daemon"),
            false)
        XCTAssertNil(
            LaunchAtLoginService.parseDisabled(noOverride, label: "com.meetingpipe.daemon"),
            "absence is not an override")
        XCTAssertNil(LaunchAtLoginService.parseDisabled("", label: "com.meetingpipe.daemon"))
    }

    func test_parser_does_not_match_a_label_that_merely_starts_with_ours() {
        let output = "\t\t\"com.meetingpipe.daemon.helper\" => disabled"
        XCTAssertNil(
            LaunchAtLoginService.parseDisabled(output, label: "com.meetingpipe.daemon"),
            "the closing quote is what keeps a sibling label from answering for us")
    }

    func test_parser_tolerates_launchctls_spacing() {
        let output = "        \"com.meetingpipe.daemon\"   =>   disabled   "
        XCTAssertEqual(
            LaunchAtLoginService.parseDisabled(output, label: "com.meetingpipe.daemon"), true)
    }

    func test_the_label_is_the_agent_installed_by_install_sh() {
        // Same string as the app's bundle id, a known sharp edge carried rather
        // than fixed (UX42 scope). It has to match scripts/launchd.plist.template.
        XCTAssertEqual(LaunchAtLoginService.label, "com.meetingpipe.daemon")
        XCTAssertTrue(
            LaunchAtLoginService.defaultPlistPath
                .hasSuffix("Library/LaunchAgents/com.meetingpipe.daemon.plist"))
    }

    // MARK: - UX67: the refusal diagnostic (candidate A)

    /// The control renders the machine rather than the request, which is right and
    /// stays. What it cannot do is tell a person that the machine declined, and
    /// nobody reads the group footer they were not expecting. These pin the
    /// decision, not the sentence: a rendered string would move with the copy.
    func test_a_write_that_did_not_move_the_switch_is_a_refusal() {
        let refused = LaunchAtLoginRefusal.decide(
            requested: true,
            status: LaunchAtLoginStatus(state: .disabled, error: "Could not turn launch at login on: launchctl exited 5. Boot-out failed")
        )
        XCTAssertEqual(refused?.requested, true)
        XCTAssertEqual(refused?.resulting, .disabled)
        XCTAssertEqual(refused?.reason.contains("launchctl exited 5"), true,
                       "the exit status and the stderr tail are the whole point of logging it")
    }

    func test_a_write_that_landed_logs_nothing() {
        XCTAssertNil(LaunchAtLoginRefusal.decide(
            requested: true, status: LaunchAtLoginStatus(state: .enabled, error: nil)))
        XCTAssertNil(LaunchAtLoginRefusal.decide(
            requested: false, status: LaunchAtLoginStatus(state: .disabled, error: nil)))
        XCTAssertNil(LaunchAtLoginRefusal.decide(
            requested: false, status: LaunchAtLoginStatus(state: .notInstalled, error: nil)),
            "not installed is off, and asking for off got it")
    }

    /// The sharper case: launchctl claimed success and the state still did not
    /// move. No footer would have shown this one at all, so staying quiet here
    /// would leave the worst variant the least visible.
    func test_a_silent_refusal_still_logs() {
        let refused = LaunchAtLoginRefusal.decide(
            requested: true, status: LaunchAtLoginStatus(state: .notInstalled, error: nil))
        XCTAssertNotNil(refused)
        XCTAssertEqual(refused?.reason, "launchctl reported no error")
    }

    // MARK: - UX67: the pane re-reads (candidate B)

    /// The defect: the model read once in `init` and nothing re-read on open, on
    /// foreground, or on any notification, so a `rebuild.sh` moving the agent
    /// underneath left the pane rendering what was true when the view was built.
    /// Counted on the runner, which is the only place a read is observable.
    @MainActor
    func test_the_model_re_reads_when_the_pane_appears() async {
        let runner = FakeLaunchctl(printDisabled: printDisabled("disabled"))
        let model = LaunchAtLoginModel(service: service(runner))

        XCTAssertEqual(runner.count("print-disabled"), 1, "the initial read")
        XCTAssertFalse(model.status.isOn)

        // The agent changes underneath, the way install.sh or rebuild.sh does it.
        runner.responses["print-disabled"] = LaunchctlResult(status: 0, output: printDisabled("enabled"))

        await model.refresh()?.value

        XCTAssertEqual(runner.count("print-disabled"), 2, "appearing re-takes the reading")
        XCTAssertTrue(model.status.isOn, "and the pane shows what the machine now holds")
    }

    /// Not a per-render read. `status()` spawns a subprocess, and UX55 recorded
    /// what an inline read on a hot path costs; a re-appear mid-write must not
    /// stack a second one either.
    @MainActor
    func test_a_refresh_while_one_is_in_flight_does_not_stack_a_second_read() async {
        let runner = FakeLaunchctl(printDisabled: printDisabled("enabled"))
        let model = LaunchAtLoginModel(service: service(runner))

        let first = model.refresh()
        XCTAssertNil(model.refresh(), "the second is refused while the first is in flight")
        await first?.value

        XCTAssertEqual(runner.count("print-disabled"), 2, "init plus exactly one refresh")
    }

    /// A write still reports what launchd is left holding (UX42's rule, unchanged)
    /// and clears `isBusy` when it lands, so the control comes back.
    @MainActor
    func test_a_write_publishes_the_machines_answer_and_clears_busy() async {
        let runner = FakeLaunchctl(printDisabled: noOverride)
        let model = LaunchAtLoginModel(service: service(runner))

        await model.set(enabled: false)?.value

        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.status.state, .disabled)
        XCTAssertTrue(runner.verbs.contains("disable"))
    }
}
