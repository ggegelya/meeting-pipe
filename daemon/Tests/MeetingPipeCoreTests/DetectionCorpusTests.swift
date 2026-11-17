import Foundation
import XCTest
@testable import MeetingPipeCore

/// Detection regression corpus (TECH-C6). Loads every trace named in
/// `Fixtures/detection-corpus/INDEX.json` and replays it through the
/// matching engine (PromotionEngine for `promotion`, MicGate.decide for
/// `micgate`, and since T8 `LifecycleTraceReplay` for `lifecycle`: the
/// engine, the hold policy and the teardown oracle together on a virtual
/// clock). Any deviation between the replay and the captured
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
        let legacy = try loadIndex(list: "legacy_characterization")
        XCTAssertGreaterThanOrEqual(traces.count, 5, "Corpus should grow over Phase 2 dogfood")
        for name in traces + legacy {
            XCTAssertNotNil(traceURL(name: name), "Missing trace file: \(name)")
        }
        XCTAssertTrue(Set(traces).isDisjoint(with: legacy), "a trace is either a scenario or legacy, never both")
    }

    func test_every_corpus_trace_replays_to_expected_verdicts() throws {
        let traces = try loadIndex()
        for name in traces {
            try replay(traceName: name)
        }
    }

    /// T17: the 20 distilled `teams_native_{rewalk,flicker_rewalk,debounce}_end_*` traces and the two
    /// seeds that end on the host's confirm pseudo-event. They are four event structures rebuilt from
    /// logged verdicts, and 18 of them answer their own end through `confirm_provisional_end`, so they
    /// pin the provisional transitions and the flicker reverts and are evidence for no end rule.
    /// Replayed and listed apart so their count is never read as coverage.
    func test_every_legacy_characterization_trace_replays_to_expected_verdicts() throws {
        let legacy = try loadIndex(list: "legacy_characterization")
        XCTAssertEqual(legacy.count, 22, "the legacy set is closed: a new trace goes in scenarios")
        for name in legacy {
            try replay(traceName: name)
        }
    }

    // MARK: - T17: the pseudo-event fence

    /// A trace in `scenarios` may not answer its own end. `confirm_provisional_end` takes the engine
    /// straight to `.ended` from any provisional, so the dwells, the live veto, the revert rule and
    /// the teardown oracle never decide a trace that carries it.
    func test_no_scenario_answers_its_own_end_with_the_pseudo_event() throws {
        let offenders = try Self.tracesCarryingThePseudoEvent(try loadIndex()) { name in
            guard let url = traceURL(name: name) else { return nil }
            return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        }
        XCTAssertEqual(offenders, [], "move these to legacy_characterization or end them on a real rule")
    }

    /// The fence can fail.
    func test_the_pseudo_event_fence_names_a_scenario_that_carries_it() throws {
        let traces: [String: [String: Any]] = [
            "clean.json": ["events": [["t": 0.0, "kind": "ax_leave_button", "state": "live"]]],
            "cheat.json": ["events": [
                ["t": 0.0, "kind": "ax_leave_button", "state": "ended"],
                ["t": 1.0, "kind": "confirm_provisional_end", "rewalk_signal": "ax_leave_rewalk"],
            ]],
        ]
        let offenders = try Self.tracesCarryingThePseudoEvent(["clean.json", "cheat.json"]) { traces[$0] }
        XCTAssertEqual(offenders, ["cheat.json"])
    }

    static func tracesCarryingThePseudoEvent(
        _ names: [String], load: (String) throws -> [String: Any]?
    ) throws -> [String] {
        try names.filter { name in
            let events = (try load(name)?["events"] as? [[String: Any]]) ?? []
            return events.contains { ($0["kind"] as? String) == "confirm_provisional_end" }
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
        case "lifecycle":
            try replayLifecycle(traceName: traceName, json: json)
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
        let context = try makeContext(contextJson)

        let engine = PromotionEngine()
        engine.reset(awaitingVetoer: LifecycleTraceReplay.publishesProcessAudio(context))
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
            if kind == "confirm_provisional_end" {
                // The host's definitive confirm, `PromotionEngine.confirmProvisionalEnd`. Since END17 its
                // one caller is Teams' teardown line for this recording (`call_teardown_observed`); the
                // real traces extracted before that carry `ax_leave_rewalk`, the string the pre-END17 host
                // recorded for the same call. A native Teams end replays through this pseudo-event
                // because the engine on its own would wait out a dwell the host never needs to.
                let evidence = (event["rewalk_signal"] as? String) ?? PromotionEngine.teardownEvidence
                if let decision = engine.confirmProvisionalEnd(evidence: evidence) {
                    observed.append((index, decision.verdict))
                }
                continue
            }
            let signalKind = try mapSignalKind(kind)
            let stateString = (event["state"] as? String) ?? "live"
            let state: PrimarySignalState = stateString == "ended" ? .ended : stateString == "unknown" ? .unknown : .live
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
        // END17: an incident trace says outright that the call must survive, so a later edit to its
        // expected verdicts cannot quietly turn a no-end trace into one that ends.
        if (json["expected_outcome"] as? String) == "no_end" {
            XCTAssertFalse(
                observed.contains { if case .ended = $0.verdict { return true } else { return false } },
                "\(traceName) is a live call and must never reach .ended"
            )
        }
        for (i, expectation) in expected.enumerated() where i < observed.count {
            let actual = observed[i].verdict
            try assertMatches(traceName: traceName, expectation: expectation, actual: actual, context: context)
        }
    }

    /// T8: a lifecycle trace replays the engine, the hold policy and the teardown oracle together
    /// (`LifecycleTraceReplay`) and asserts only the outcome: the call survives the window, or it
    /// ends at `ended_at` with the tail cut at `trim_at`. Times are within a second, because the
    /// consult runs at 1 Hz.
    private func replayLifecycle(traceName: String, json: [String: Any]) throws {
        let replay = try makeLifecycleReplay(traceName: traceName, json: json)
        guard let origin = json["origin"] as? String, ["raw", "synthetic"].contains(origin) else {
            return XCTFail("\(traceName) needs an 'origin' of raw or synthetic")
        }
        let outcome = replay.run()
        for violation in try truthViolations(traceName: traceName, json: json, replay: replay, outcome: outcome) {
            XCTFail(violation)
        }
        switch json["expected_outcome"] as? String {
        case "no_end":
            XCTAssertNil(
                outcome.endedAt,
                "\(traceName) is a live call and must never reach .ended (ended at \(outcome.endedAt.map { "\($0.timeIntervalSince1970)" } ?? "-"))"
            )
        case "ended":
            guard let endedAt = json["ended_at"] as? Double else {
                return XCTFail("\(traceName) expects an end but has no 'ended_at'")
            }
            guard let actual = outcome.endedAt else {
                return XCTFail("\(traceName) never ended; expected an end at \(endedAt)")
            }
            XCTAssertEqual(actual.timeIntervalSince1970, endedAt, accuracy: 1.0, "\(traceName) ended at the wrong moment")
            if let trimAt = json["trim_at"] as? Double {
                XCTAssertEqual(outcome.trimAt?.timeIntervalSince1970 ?? .nan, trimAt, accuracy: 1.0, "\(traceName) trim point")
            } else {
                XCTAssertNil(outcome.trimAt, "\(traceName) expects no trim (a sub-second hold, or none)")
            }
        default:
            XCTFail("\(traceName) 'expected_outcome' must be no_end or ended")
        }
    }

    /// The harness has to be able to fail. Replayed against an engine whose lone dwell is 30 s, the
    /// END12 shape (a Leave button invalid for three minutes of a live call) ends and is trimmed back
    /// to where the hold opened, which is the class of regression a lifecycle trace exists to catch.
    func test_a_lifecycle_trace_catches_a_policy_that_ends_too_early() throws {
        let name = "teams_native_lifecycle_end12_quiet_log.json"
        guard let url = traceURL(name: name),
              let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            return XCTFail("missing \(name)")
        }
        let replay = try makeLifecycleReplay(traceName: name, json: json)

        XCTAssertNil(replay.run().endedAt, "the shipped dwells hold it")

        let early = replay.run(engine: PromotionEngine(loneDwell: 30))
        let endedAt = try XCTUnwrap(early.endedAt, "a 30 s lone dwell ends the live call")
        XCTAssertEqual(endedAt.timeIntervalSince1970, 330, accuracy: 0.5)
        // END21: this trace carries no process audio, so a lone-dwell end is no evidence of when
        // the call ended and cuts nothing (the owner's decision of 2026-11-16, F032).
        XCTAssertNil(early.trimAt, "a lone-dwell end without process audio trims nothing")
    }

    // MARK: - T17: truth labels

    /// What is wrong with a replay against the trace's `truth`, empty when it passes or has none.
    private func truthViolations(
        traceName: String, json: [String: Any], replay: LifecycleTraceReplay, outcome: LifecycleTraceReplay.Outcome
    ) throws -> [String] {
        guard let truthJson = json["truth"] else { return [] }
        let until = replay.until.timeIntervalSince1970
        let truth = try makeTruth(traceName: traceName, truthJson, until: until)
        return truth.violations(replayedEnd: outcome.endedAt?.timeIntervalSince1970, until: until)
            .map { "\(traceName) against its truth (\(truth.source.rawValue)): \($0)" }
    }

    /// The JSON path can fail too: a trace file whose truth says the call ran to 240 s, replayed to
    /// the pair dwell's end at 90 s, reports the lost seconds through the same check the corpus runs.
    func test_a_truth_label_in_a_trace_file_fails_an_early_end() throws {
        let json: [String: Any] = [
            "context": ["bundle_id": "com.microsoft.teams2", "kind": "native", "pid": 1234],
            "until": 300.0,
            "truth": ["call_ended_at": 240.0, "truth_source": "owner_stop", "max_overrun_sec": 10.0],
            "events": [
                ["t": 0.0, "kind": "process_audio_is_running_input_false", "state": "live"],
                ["t": 0.0, "kind": "ax_leave_button", "state": "live"],
                ["t": 1.0, "kind": "recording_started"],
                ["t": 30.0, "kind": "ax_leave_button", "state": "ended"],
                ["t": 30.0, "kind": "process_audio_is_running_input_false", "state": "ended"],
            ],
        ]
        let replay = try makeLifecycleReplay(traceName: "in_memory", json: json)
        let violations = try truthViolations(traceName: "in_memory", json: json, replay: replay, outcome: replay.run())
        XCTAssertEqual(violations.count, 1)
        XCTAssertTrue(violations.first?.contains("seconds_lost") ?? false)
    }

    private func makeTruth(traceName: String, _ value: Any, until: TimeInterval) throws -> LifecycleTruth {
        guard let json = value as? [String: Any],
              Set(json.keys) == ["call_ended_at", "truth_source", "max_overrun_sec"],
              let source = (json["truth_source"] as? String).flatMap(LifecycleTruth.Source.init(rawValue:)) else {
            XCTFail("\(traceName) truth must be {call_ended_at, truth_source, max_overrun_sec} with a known source")
            throw NSError(domain: "DetectionCorpus", code: 7)
        }
        let callEndedAt = json["call_ended_at"] as? Double
        let maxOverrun = json["max_overrun_sec"] as? Double
        if let call = callEndedAt {
            // A call end the window cannot outlast by the allowed overrun would pass with no end at
            // all, since a missing end is scored as overrunning only to `until`.
            guard let maxOverrun, call >= 0, call + maxOverrun < until else {
                XCTFail("\(traceName) truth needs 0 <= call_ended_at and call_ended_at + max_overrun_sec < until")
                throw NSError(domain: "DetectionCorpus", code: 8)
            }
        }
        return LifecycleTruth(callEndedAt: callEndedAt, source: source, maxOverrunSec: maxOverrun)
    }

    /// The bar can fail: a truth-labelled trace whose replay ends 60 s into a call that ran to 240 s
    /// scores the lost minute, and the assertion fires on it.
    func test_a_truth_labelled_trace_that_ends_early_reports_the_seconds_lost() {
        let context = MeetingLifecycleContext(bundleID: "com.microsoft.teams2", kind: .native, pid: 1234)
        let at = { Date(timeIntervalSince1970: $0) }
        let replay = LifecycleTraceReplay(
            context: context,
            events: [
                (at(0), .signal(.processAudioIsRunningInput, .live)),
                (at(0), .signal(.axLeaveButton, .live)),
                (at(1), .recordingStarted),
                (at(30), .signal(.axLeaveButton, .ended)),
                (at(30), .signal(.processAudioIsRunningInput, .ended)),
            ],
            until: at(300)
        )
        let ended = replay.run().endedAt?.timeIntervalSince1970
        XCTAssertEqual(ended ?? .nan, 90, accuracy: 1, "the pair dwell ends it")

        let truth = LifecycleTruth(callEndedAt: 240, source: .ownerLabel, maxOverrunSec: 10)
        let score = truth.score(replayedEnd: ended, until: 300)
        XCTAssertGreaterThan(score.secondsLost, 0)
        XCTAssertEqual(score.secondsLost, 150, accuracy: 1)
        XCTAssertFalse(truth.violations(replayedEnd: ended, until: 300).isEmpty, "the assertion fails")
    }

    func test_truth_scoring_edge_cases() {
        let live = LifecycleTruth(callEndedAt: nil, source: .ownerLabel, maxOverrunSec: nil)
        XCTAssertEqual(live.score(replayedEnd: nil, until: 90), .init(secondsLost: 0, overrunSec: 0))
        XCTAssertEqual(live.score(replayedEnd: 30, until: 90), .init(secondsLost: 60, overrunSec: 0),
                       "a live call that replays to an end loses the rest of the window")

        let ends = LifecycleTruth(callEndedAt: 100, source: .micRelease, maxOverrunSec: 70)
        XCTAssertEqual(ends.score(replayedEnd: 160, until: 900), .init(secondsLost: 0, overrunSec: 60))
        XCTAssertTrue(ends.violations(replayedEnd: 160, until: 900).isEmpty)
        XCTAssertEqual(ends.score(replayedEnd: nil, until: 900), .init(secondsLost: 0, overrunSec: 800),
                       "a call end the replay never reached overruns at least to the window's end")
        XCTAssertFalse(ends.violations(replayedEnd: nil, until: 900).isEmpty)
    }

    // MARK: - T17: replay past an end

    /// A resume: the call ends on the pair dwell, the host engages afresh (END27's re-engage at a
    /// record start), and the second call ends the same way. Both ends are recorded.
    func test_a_lifecycle_replay_goes_on_past_an_end_and_records_a_resumed_calls_end() {
        let context = MeetingLifecycleContext(bundleID: "com.microsoft.teams2", kind: .native, pid: 1234)
        let at = { Date(timeIntervalSince1970: $0) }
        let firstCall: [(at: Date, event: LifecycleTraceReplay.Event)] = [
            (at(0), .signal(.processAudioIsRunningInput, .live)),
            (at(0), .signal(.axLeaveButton, .live)),
            (at(1), .recordingStarted),
            (at(30), .signal(.axLeaveButton, .ended)),
            (at(30), .signal(.processAudioIsRunningInput, .ended)),
        ]
        // The host's order: the resume's recording starts, then its build lands and END27 re-engages
        // the terminal engine, which `confirmLateStartIfRecording` takes to `.inMeeting`.
        let resume: [(at: Date, event: LifecycleTraceReplay.Event)] = [
            (at(120), .recordingStarted),
            (at(120.5), .engage),
            (at(120.5), .signal(.processAudioIsRunningInput, .live)),
            (at(120.5), .signal(.axLeaveButton, .live)),
            (at(200), .signal(.axLeaveButton, .ended)),
            (at(200), .signal(.processAudioIsRunningInput, .ended)),
        ]
        let outcome = LifecycleTraceReplay(context: context, events: firstCall + resume, until: at(400)).run()
        XCTAssertEqual(outcome.ends.map { $0.at.timeIntervalSince1970 }.count, 2)
        XCTAssertEqual(outcome.ends.first?.at.timeIntervalSince1970 ?? .nan, 90, accuracy: 1)
        XCTAssertEqual(outcome.ends.last?.at.timeIntervalSince1970 ?? .nan, 260, accuracy: 1)
        let startings = outcome.verdicts.filter { if case .starting = $0.verdict { return true } else { return false } }
        XCTAssertEqual(startings.count, 2, "the fresh engine starts again")

        let inMeeting = outcome.verdicts.filter { if case .inMeeting = $0.verdict { return true } else { return false } }
        XCTAssertEqual(inMeeting.count, 2, "the re-engaged engine is confirmed into .inMeeting, so its end is held")

        // Without the host's engage, the ended engine ignores the second call, as at HEAD.
        let noEngage = firstCall + resume.filter { if case .engage = $0.event { return false } else { return true } }
        XCTAssertEqual(LifecycleTraceReplay(context: context, events: noEngage, until: at(400)).run().ends.count, 1)
    }

    /// An `engage` the build of its day made after its own end is a no-op while today's engine has
    /// not ended: the old build's reaction must not cut a later end.
    func test_an_engage_reaching_a_live_engine_changes_nothing() {
        let context = MeetingLifecycleContext(bundleID: "com.microsoft.teams2", kind: .native, pid: 1234)
        let at = { Date(timeIntervalSince1970: $0) }
        let call: [(at: Date, event: LifecycleTraceReplay.Event)] = [
            (at(0), .signal(.processAudioIsRunningInput, .live)),
            (at(0), .signal(.axLeaveButton, .live)),
            (at(1), .recordingStarted),
            (at(30), .signal(.axLeaveButton, .ended)),
            (at(30), .signal(.processAudioIsRunningInput, .ended)),
        ]
        let withEngage = call + [(at(60), .engage)]
        let plain = LifecycleTraceReplay(context: context, events: call, until: at(300)).run()
        let engaged = LifecycleTraceReplay(context: context, events: withEngage, until: at(300)).run()
        XCTAssertEqual(engaged.ends.map(\.at), plain.ends.map(\.at))
        XCTAssertEqual(engaged.ends.first?.at.timeIntervalSince1970 ?? .nan, 90, accuracy: 1)
    }

    private func makeLifecycleReplay(traceName: String, json: [String: Any]) throws -> LifecycleTraceReplay {
        guard let contextJson = json["context"] as? [String: Any],
              let events = json["events"] as? [[String: Any]],
              let until = json["until"] as? Double else {
            XCTFail("\(traceName) missing context/events/until")
            throw NSError(domain: "DetectionCorpus", code: 2)
        }
        let context = try makeContext(contextJson)
        var timeline: [(at: Date, event: LifecycleTraceReplay.Event)] = []
        for (index, event) in events.enumerated() {
            guard let t = event["t"] as? Double, let kind = event["kind"] as? String else {
                XCTFail("\(traceName).events[\(index)] needs 't' and 'kind'")
                throw NSError(domain: "DetectionCorpus", code: 3)
            }
            let at = Date(timeIntervalSince1970: t)
            switch kind {
            case "recording_started":
                timeline.append((at, .recordingStarted))
            case "teardown_snapshot":
                guard let available = event["available"] as? Bool else {
                    XCTFail("\(traceName).events[\(index)] teardown_snapshot needs 'available'")
                    throw NSError(domain: "DetectionCorpus", code: 4)
                }
                let teardownAt = (event["teardown_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                timeline.append((at, .teardownSnapshot(available: available, teardownAt: teardownAt)))
            case "live_signal":
                let value = (event["value"] as? String) ?? ""
                guard CallTeardownOracle.LiveCallSignal(rawValue: value) != nil else {
                    XCTFail("\(traceName).events[\(index)] live_signal value \(value) is not a LiveCallSignal")
                    throw NSError(domain: "DetectionCorpus", code: 5)
                }
                timeline.append((at, .liveSignal(value)))
            case "rewalk":
                timeline.append((at, .rewalk(found: (event["found"] as? Bool) ?? false)))
            case "engage":
                timeline.append((at, .engage))
            default:
                let signal = try mapSignalKind(kind)
                let state: PrimarySignalState
                switch event["state"] as? String {
                case "live": state = .live
                case "ended": state = .ended
                case "unknown": state = .unknown
                default:
                    XCTFail("\(traceName).events[\(index)] signal state must be live, ended or unknown")
                    throw NSError(domain: "DetectionCorpus", code: 6)
                }
                timeline.append((at, .signal(signal, state)))
            }
        }
        return LifecycleTraceReplay(context: context, events: timeline, until: Date(timeIntervalSince1970: until))
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

    private func loadIndex(list: String = "scenarios") throws -> [String] {
        guard let url = Bundle.module.url(forResource: "INDEX", withExtension: "json") else {
            XCTFail("INDEX.json missing from test bundle")
            return []
        }
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scenarios = json[list] as? [String] else {
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
        case "workspace_app_terminated":
            return .workspaceAppTerminated
        case "window_title":
            return .windowTitleLeftPattern
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
