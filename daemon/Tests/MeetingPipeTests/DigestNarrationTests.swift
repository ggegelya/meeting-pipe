import XCTest
@testable import MeetingPipe

/// UX63. The footer said "on-device (no new egress)" while the scheduled run
/// posted to Anthropic every Monday, so what these pin is the join: the engine
/// the copy names is the engine the pipeline will actually use, and the promise
/// about the network is derived from that rather than asserted beside it.
final class DigestNarrationTests: XCTestCase {

    private func engine(_ backend: String, regulated: Bool = false, localOnly: Bool = false) -> SummarizationEngine? {
        DigestNarration.engine(configuredBackend: backend, regulatedMode: regulated, localOnly: localOnly)
    }

    private func footer(_ backend: String, regulated: Bool = false, localOnly: Bool = false) -> String {
        DigestNarration.footer(configuredBackend: backend, regulatedMode: regulated, localOnly: localOnly)
    }

    // MARK: - Which engine will run

    /// The observed case: a launchd job on this config posts to Anthropic.
    func testACloudBackendNarratesInTheCloud() {
        XCTAssertEqual(engine("anthropic"), .anthropic)
        XCTAssertEqual(engine("anthropic")?.locality, .cloud)
    }

    func testTheOptOutPinsItLocalFromEveryBackend() {
        for e in SummarizationEngine.all {
            XCTAssertEqual(
                engine(e.id, localOnly: true), .local,
                "digest_local_only did not pin \(e.id) to the on-device engine"
            )
        }
    }

    /// The three narrowing rules compose, and none of them can select a cloud
    /// engine, which is why they need no precedence argument.
    func testRegulatedModeNarrowsItWithoutTheOptOut() {
        XCTAssertEqual(engine("anthropic", regulated: true), .local)
        XCTAssertEqual(engine("claude_cli", regulated: true), .local)
    }

    /// `mp digest` has no Apple Intelligence path, so the narration lands on the
    /// local MLX model. Naming Apple Intelligence in the footer would be the same
    /// untruth in a new place (UX64 renders the matching line in Ask).
    func testAppleIntelligenceResolvesToTheEngineThatActuallyRuns() {
        XCTAssertEqual(engine("apple_intelligence"), .local)
    }

    /// `auto` is reported as itself: it picks per run on whether the cloud
    /// answered, so predicting one here would be a guess, and its own name
    /// already says "cloud, fall back to local".
    func testAutoIsReportedAsItselfRatherThanGuessed() {
        XCTAssertEqual(engine("auto"), .auto)
        XCTAssertEqual(engine("auto")?.locality, .cloudThenLocal)
    }

    func testAnUnnameableBackendResolvesToNil() {
        XCTAssertNil(engine("some_future_vendor"))
    }

    // MARK: - The promise is derived, not asserted

    func testStaysOnThisMacTracksTheResolvedEngine() {
        XCTAssertFalse(DigestNarration.staysOnThisMac(
            configuredBackend: "anthropic", regulatedMode: false, localOnly: false))
        XCTAssertTrue(DigestNarration.staysOnThisMac(
            configuredBackend: "anthropic", regulatedMode: false, localOnly: true))
        XCTAssertTrue(DigestNarration.staysOnThisMac(
            configuredBackend: "anthropic", regulatedMode: true, localOnly: false))
        // Cloud-then-local is not a promise anybody can make in advance.
        XCTAssertFalse(DigestNarration.staysOnThisMac(
            configuredBackend: "auto", regulatedMode: false, localOnly: false))
    }

    /// The whole defect in one assertion: a footer that promises the network is
    /// untouched may appear only over routing that cannot touch it.
    func testTheNothingLeavesPromiseAppearsExactlyWhenItIsTrue() {
        for e in SummarizationEngine.all {
            for regulated in [false, true] {
                for localOnly in [false, true] {
                    let text = footer(e.id, regulated: regulated, localOnly: localOnly)
                    let claimsSafe = text.contains("nothing leaves it")
                    let isSafe = DigestNarration.staysOnThisMac(
                        configuredBackend: e.id, regulatedMode: regulated, localOnly: localOnly
                    )
                    XCTAssertEqual(
                        claimsSafe, isSafe,
                        "\(e.id) regulated=\(regulated) localOnly=\(localOnly): \(text)"
                    )
                }
            }
        }
    }

    /// And the mirror: whenever it does go out, the footer says so and names
    /// where, rather than leaving the reader to infer it from an absence.
    func testACloudNarrationIsNamedAndTheOptOutIsPointedAt() {
        let text = footer("anthropic")
        XCTAssertTrue(text.contains("Anthropic"), text)
        XCTAssertTrue(text.contains("sent there on every run"), text)
        // The unattended half, which is what made this worth a task: nobody is
        // watching the Monday 09:00 run.
        XCTAssertTrue(text.contains("scheduled ones nobody is watching"), text)
        XCTAssertTrue(text.contains(DigestNarration.toggleTitle), text)
    }

    /// The old parenthetical is gone, and what replaced it says the true thing
    /// the qualified form always said: this is about scheduling, not the network.
    func testTheOldEgressParentheticalIsNotResurrected() {
        for e in SummarizationEngine.all {
            let text = footer(e.id)
            XCTAssertFalse(text.contains("no new egress"), text)
            XCTAssertTrue(text.contains("never continuously"), text)
        }
    }

    func testFooterNeverLeaksARawConfigID() {
        for e in SummarizationEngine.all {
            for localOnly in [false, true] {
                let text = footer(e.id, localOnly: localOnly)
                    + DigestNarration.toggleSublabel(
                        configuredBackend: e.id, regulatedMode: false, localOnly: localOnly
                    )
                for other in SummarizationEngine.all {
                    XCTAssertFalse(text.contains(other.id), "raw id in: \(text)")
                }
            }
        }
    }

    /// An engine this build cannot name says nothing about where the narrative
    /// goes rather than guessing, the nil-over-fallback rule the Ask footer and
    /// the provenance row both follow.
    func testAnUnnameableBackendMakesNoClaimEitherWay() {
        let text = footer("some_future_vendor")
        XCTAssertFalse(text.contains("nothing leaves it"), text)
        XCTAssertFalse(text.contains("sent there"), text)
        XCTAssertTrue(text.contains("gathers your open actions"), text)
    }

    /// The toggle stays enabled on a config where it changes nothing, because it
    /// is a durable preference that matters the next time the backend moves; the
    /// sublabel is what has to be honest there.
    func testTheSublabelSaysWhenTheToggleChangesNothingToday() {
        let already = DigestNarration.toggleSublabel(
            configuredBackend: "local", regulatedMode: false, localOnly: false
        )
        XCTAssertTrue(already.contains("already run on this Mac"), already)
        XCTAssertTrue(already.contains("if you switch engines later"), already)
    }

    func testNoEmDashesInAnyCopy() {
        var strings = [DigestNarration.toggleTitle]
        for e in SummarizationEngine.all {
            for localOnly in [false, true] {
                strings.append(footer(e.id, localOnly: localOnly))
                strings.append(DigestNarration.toggleSublabel(
                    configuredBackend: e.id, regulatedMode: false, localOnly: localOnly
                ))
            }
        }
        for s in strings {
            XCTAssertFalse(s.contains("\u{2014}"), "em-dash in: \(s)")
        }
    }
}
