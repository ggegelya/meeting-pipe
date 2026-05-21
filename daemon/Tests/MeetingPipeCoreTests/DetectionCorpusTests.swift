import Foundation
import XCTest
@testable import MeetingPipeCore

/// Detection regression corpus (TECH-C6). Loads every trace named in
/// `Fixtures/detection-corpus/INDEX.json` and replays it through the
/// matching engine (PromotionEngine for lifecycle, MicGate.decide for
/// gate). Any deviation between the replay and the captured
/// expectation fails CI; new regressions to either engine surface
/// here before they reach the dogfood window.
///
/// The Phase 2 dogfood window grows this corpus with user-recorded
/// traces; the initial set below covers the load-bearing scenarios
/// (clean leave, post-call chat grab, Webex ultrasound retention,
/// browser-only Meet, MicGate precedence corners) so a single trace
/// file is enough to lock in each invariant.
final class DetectionCorpusTests: XCTestCase {

    func test_corpus_index_is_loadable_and_lists_every_referenced_trace() throws {
        let traces = try loadIndex()
        XCTAssertGreaterThanOrEqual(traces.count, 5, "Corpus should grow over Phase 2 dogfood")
        for name in traces {
            XCTAssertNotNil(traceURL(name: name), "Missing trace file: \(name)")
        }
    }

    func test_every_corpus_trace_replays_to_expected_verdicts() throws {
        let traces = try loadIndex()
        for name in traces {
            try replay(traceName: name)
        }
    }

    // MARK: - Replay

    private func replay(traceName: String) throws {
        guard let url = traceURL(name: traceName) else {
            return XCTFail("Missing trace file: \(traceName)")
        }
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("\(traceName) is not a JSON object")
        }
        guard let engine = json["engine"] as? String else {
            return XCTFail("\(traceName) missing 'engine' field")
        }
        switch engine {
        case "promotion":
            try replayPromotion(traceName: traceName, json: json)
        case "micgate":
            try replayMicGate(traceName: traceName, json: json)
        default:
            XCTFail("\(traceName) unknown engine \(engine)")
        }
    }

    private func replayPromotion(traceName: String, json: [String: Any]) throws {
        guard let contextJson = json["context"] as? [String: Any],
              let events = json["events"] as? [[String: Any]],
              let expected = json["expected_verdicts"] as? [[String: Any]] else {
            return XCTFail("\(traceName) missing context/events/expected_verdicts")
        }
        let debounce = (json["debounce_seconds"] as? Double) ?? 2.0
        let context = try makeContext(contextJson)

        let engine = PromotionEngine(debounce: debounce)
        var observed: [(eventIndex: Int, verdict: MeetingLifecycleVerdict)] = []

        for (index, event) in events.enumerated() {
            let t = (event["t"] as? Double) ?? 0
            let kind = (event["kind"] as? String) ?? ""
            if kind == "tick" {
                if let decision = engine.tick(at: Date(timeIntervalSince1970: t)) {
                    observed.append((index, decision.verdict))
                }
                continue
            }
            let signalKind = try mapSignalKind(kind)
            let stateString = (event["state"] as? String) ?? "live"
            let state: PrimarySignalState = stateString == "ended" ? .ended : .live
            let primaryEvent = PrimarySignalEvent(
                kind: signalKind, state: state,
                timestamp: Date(timeIntervalSince1970: t),
                context: context
            )
            if let decision = engine.ingest(primaryEvent) {
                observed.append((index, decision.verdict))
                // The corpus traces are recorded-meeting scenarios.
                // Model the user arming the recorder right after
                // discovery so each trace exercises the full
                // `.inMeeting` -> `.ended` path.
                if case .starting = decision.verdict,
                   let confirmed = engine.confirmRecording() {
                    observed.append((index, confirmed.verdict))
                }
            }
        }

        XCTAssertEqual(
            observed.count, expected.count,
            "\(traceName) observed \(observed.count) verdicts, expected \(expected.count)"
        )
        for (i, expectation) in expected.enumerated() where i < observed.count {
            let actual = observed[i].verdict
            try assertMatches(traceName: traceName, expectation: expectation, actual: actual, context: context)
        }
    }

    private func replayMicGate(traceName: String, json: [String: Any]) throws {
        guard let states = json["states"] as? [[String: Any]] else {
            return XCTFail("\(traceName) missing states")
        }
        for entry in states {
            let label = (entry["label"] as? String) ?? "?"
            guard let stateJson = entry["state"] as? [String: Any] else {
                return XCTFail("\(traceName).\(label) missing 'state'")
            }
            let state = try makeMicGateState(stateJson)
            let verdict = MicGate.decide(state: state)
            let expectedVerdict = (entry["expected_verdict"] as? String) ?? ""
            XCTAssertEqual(
                verdict.label, expectedVerdict,
                "\(traceName).\(label): verdict label mismatch"
            )
            if let expectedLabel = entry["expected_label"] as? String,
               case .mutedByApp(let actualLabel, _) = verdict {
                XCTAssertEqual(actualLabel, expectedLabel)
            }
            if let expectedLocale = entry["expected_locale"] as? String,
               case .mutedByApp(_, let actualLocale) = verdict {
                XCTAssertEqual(actualLocale, expectedLocale)
            }
            if let expectedReason = entry["expected_reason"] as? String,
               case .hot(let reason) = verdict {
                XCTAssertEqual(reason.rawValue, expectedReason)
            }
            if let expectedDwell = entry["expected_dwell"] as? Int,
               case .silentByRMS(let dwell) = verdict {
                XCTAssertEqual(dwell, expectedDwell)
            }
        }
    }

    // MARK: - Helpers

    private func loadIndex() throws -> [String] {
        guard let url = Bundle.module.url(forResource: "INDEX", withExtension: "json") else {
            XCTFail("INDEX.json missing from test bundle")
            return []
        }
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scenarios = json["scenarios"] as? [String] else {
            XCTFail("INDEX.json malformed")
            return []
        }
        return scenarios
    }

    private func traceURL(name: String) -> URL? {
        Bundle.module.url(
            forResource: (name as NSString).deletingPathExtension,
            withExtension: "json"
        )
    }

    private func makeContext(_ json: [String: Any]) throws -> MeetingLifecycleContext {
        guard let bundleID = json["bundle_id"] as? String,
              let kindString = json["kind"] as? String,
              let kind = MeetingLifecycleContext.Kind(rawValue: kindString),
              let pid = json["pid"] as? Int else {
            XCTFail("context missing required fields")
            throw NSError(domain: "DetectionCorpus", code: 0)
        }
        return MeetingLifecycleContext(
            bundleID: bundleID, kind: kind, pid: pid_t(pid),
            title: json["title"] as? String
        )
    }

    private func mapSignalKind(_ kind: String) throws -> PrimarySignalKind {
        switch kind {
        case "shareable_content_window":
            return .shareableContentWindow
        case "process_audio_is_running_input_false":
            return .processAudioIsRunningInput
        case "ax_leave_button":
            return .axLeaveButton
        case "browser_tab_title":
            return .browserTabTitle
        default:
            XCTFail("Unknown signal kind: \(kind)")
            throw NSError(domain: "DetectionCorpus", code: 1)
        }
    }

    private func assertMatches(
        traceName: String,
        expectation: [String: Any],
        actual: MeetingLifecycleVerdict,
        context: MeetingLifecycleContext
    ) throws {
        guard let label = expectation["verdict"] as? String else {
            return XCTFail("\(traceName) expectation missing 'verdict'")
        }
        switch label {
        case "starting":
            XCTAssertEqual(actual, .starting(context: context), traceName)
        case "in_meeting":
            XCTAssertEqual(actual, .inMeeting(context: context), traceName)
        case "ending_provisional":
            let leading = (expectation["leading"] as? String) ?? ""
            XCTAssertEqual(
                actual,
                .endingProvisional(context: context, reason: EndingReason(leadingSignal: leading)),
                traceName
            )
        case "ended":
            let leading = (expectation["leading"] as? String) ?? ""
            let confirmedBy = (expectation["confirmed_by"] as? [String]) ?? []
            XCTAssertEqual(
                actual,
                .ended(
                    context: context,
                    reason: EndingReason(leadingSignal: leading, confirmedBy: confirmedBy)
                ),
                traceName
            )
        default:
            XCTFail("\(traceName) unknown expected verdict label: \(label)")
        }
    }

    private func makeMicGateState(_ json: [String: Any]) throws -> MicGate.State {
        let axMuteString = json["ax_mute"] as? String
        let axMute: MuteLabels.State? = axMuteString.flatMap {
            switch $0 {
            case "muted": return .muted
            case "unmuted": return .unmuted
            case "unknown": return .unknown
            default: return nil
            }
        }
        let rmsStateString = (json["rms_state"] as? String) ?? "closed"
        let rmsState: RMSGateProbe.State = rmsStateString == "open" ? .open : .closed
        return MicGate.State(
            halSystemMute: json["hal_system_mute"] as? Bool,
            axMute: axMute,
            axLabel: json["ax_label"] as? String,
            axLocale: json["ax_locale"] as? String,
            halVad: json["hal_vad"] as? Bool,
            rmsState: rmsState,
            rmsCloseDwellMillis: (json["rms_close_dwell_millis"] as? Int) ?? 0
        )
    }
}
