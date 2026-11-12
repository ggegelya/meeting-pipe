import XCTest
@testable import MeetingPipe

/// PERF23: Facts, People and Meeting time re-read the library on every store revision in
/// uncancelled passes applied in completion order, and Meeting time's transcript cache died on every
/// rail switch. These pin the latest-wins pass, the model-owned caches and the single embeddings read.
@MainActor
final class LibraryProjectionsTests: XCTestCase {

    // MARK: - Fixtures

    /// Holds a pass on a continuation instead of blocking a cooperative-pool thread (CI8).
    private actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            open = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    private var dirs: [URL] = []

    override func tearDown() {
        for dir in dirs { try? FileManager.default.removeItem(at: dir) }
        dirs = []
        super.tearDown()
    }

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mp-perf23-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dirs.append(dir)
        return dir
    }

    private func write(_ url: URL, _ contents: String) throws {
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    private func write(_ url: URL, json: Any) throws {
        try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)
    }

    private func setMtime(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func meeting(_ stem: String, in dir: URL, title: String? = nil, hasSummary: Bool = false) -> Meeting {
        var m = Meeting(
            stem: stem,
            startedAt: Date(),
            audioURL: nil,
            recordingsDir: dir,
            summaryTitle: title,
            meetingTitle: nil,
            sourceBundleID: nil,
            sourceDisplayName: nil,
            sourceKind: nil,
            workflowName: nil,
            workflowColor: nil,
            durationSec: 60,
            backend: nil,
            modelId: nil,
            status: .done,
            failureReason: nil,
            failureStage: nil,
            searchableText: ""
        )
        m.hasSummaryJSON = hasSummary
        return m
    }

    private func summaryJSON(task: String, attendees: [String] = []) -> [String: Any] {
        [
            "title": "T",
            "summary": [],
            "decisions": ["Decided \(task)"],
            "actions": [["task": task, "owner": "Alice", "confidence": "high"]],
            "questions": [],
            "attendees": attendees,
        ]
    }

    // MARK: - ProjectionPass

    func test_pass_started_first_and_finished_last_is_not_applied() async {
        // The ordering hazard itself: apply-in-completion-order would leave "old" on screen.
        let pass = ProjectionPass<String>()
        let gate = Gate()
        var applied: [String] = []

        let first = pass.start(work: { await gate.wait(); return "old" }, apply: { applied.append($0) })
        let second = pass.start(work: { "new" }, apply: { applied.append($0) })
        await second.value
        await gate.release()
        await first.value

        XCTAssertEqual(applied, ["new"], "the superseded pass finished last and must not land")
    }

    func test_starting_a_pass_cancels_the_previous_one() async {
        let pass = ProjectionPass<Bool>()
        let gate = Gate()
        var sawCancelled: Bool?

        let first = pass.start(
            work: { await gate.wait(); return Task.isCancelled },
            keep: { sawCancelled = $0 },
            apply: { _ in }
        )
        pass.start(work: { false }, apply: { _ in })
        await gate.release()
        await first.value

        XCTAssertEqual(sawCancelled, true, "a superseded pass is told to stop reading")
    }

    func test_superseded_pass_still_reaches_keep() async {
        // Content-keyed caches merge every pass's measurements, or a revision burst during a
        // cold pass restarts from nothing on every bump.
        let pass = ProjectionPass<String>()
        let gate = Gate()
        var kept: [String] = []
        var applied: [String] = []

        let first = pass.start(
            work: { await gate.wait(); return "old" },
            keep: { kept.append($0) },
            apply: { applied.append($0) }
        )
        let second = pass.start(work: { "new" }, keep: { kept.append($0) }, apply: { applied.append($0) })
        await second.value
        await gate.release()
        await first.value

        XCTAssertEqual(Set(kept), ["old", "new"])
        XCTAssertEqual(applied, ["new"])
    }

    func test_cancel_drops_the_pass_in_flight() async {
        let pass = ProjectionPass<String>()
        let gate = Gate()
        var applied: [String] = []
        let first = pass.start(work: { await gate.wait(); return "late" }, apply: { applied.append($0) })
        pass.cancel()
        await gate.release()
        await first.value
        XCTAssertEqual(applied, [])
    }

    // MARK: - Facts

    func test_facts_reload_shows_the_newer_snapshot_when_the_older_pass_lands_last() async throws {
        let dir = try tempDir()
        let gate = Gate()
        // The loader reports which snapshot it read through the meeting title it was handed.
        let projection = FactsProjection { meetings, _, cache in
            let title = meetings.first?.displayTitle ?? ""
            if title == "older" { await gate.wait() }
            let fact = OpenActionFact(
                stem: "s", summaryURL: dir, meetingTitle: title, meetingDate: Date(),
                actionIndex: 0, task: "t", owner: nil, due: nil
            )
            return FactsLoader.Pass(actions: [fact], cache: cache, complete: true)
        }
        var shown: [String] = []

        let older = projection.reload(meetings: [meeting("s", in: dir, title: "older")]) {
            shown.append($0.actions.first?.meetingTitle ?? "")
        }
        let newer = projection.reload(meetings: [meeting("s", in: dir, title: "newer")]) {
            shown.append($0.actions.first?.meetingTitle ?? "")
        }
        await newer.value
        await gate.release()
        await older.value

        XCTAssertEqual(shown, ["newer"])
    }

    func test_facts_cache_redecodes_only_the_summary_that_changed() async throws {
        let dir = try tempDir()
        let a = dir.appendingPathComponent("a.summary.json")
        let b = dir.appendingPathComponent("b.summary.json")
        try write(a, json: summaryJSON(task: "A1"))
        try write(b, json: summaryJSON(task: "B1"))
        let base = Date(timeIntervalSinceNow: -3600)
        try setMtime(a, base)
        try setMtime(b, base)
        let meetings = [meeting("a", in: dir, hasSummary: true), meeting("b", in: dir, hasSummary: true)]

        let first = FactsLoader.load(meetings: meetings)
        XCTAssertEqual(Set(first.decoded), ["a", "b"])
        XCTAssertEqual(Set(first.actions.map(\.task)), ["A1", "B1"])

        let second = FactsLoader.load(meetings: meetings, cache: first.cache)
        XCTAssertEqual(second.decoded, [], "unchanged summaries come from the cache")
        XCTAssertEqual(Set(second.actions.map(\.task)), ["A1", "B1"])

        try write(b, json: summaryJSON(task: "B2"))
        try setMtime(b, base.addingTimeInterval(60))
        let third = FactsLoader.load(meetings: meetings, cache: second.cache)
        XCTAssertEqual(third.decoded, ["b"])
        XCTAssertEqual(Set(third.actions.map(\.task)), ["A1", "B2"])
    }

    func test_facts_cache_does_not_pin_an_unreadable_summary() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("a.summary.json")
        try write(url, "not json")
        let meetings = [meeting("a", in: dir, hasSummary: true)]
        let pass = FactsLoader.load(meetings: meetings)
        XCTAssertTrue(pass.cache.entries.isEmpty, "a failed decode is retried, never stored")
    }

    // MARK: - Meeting time

    private func transcript(_ speakers: [String]) -> [String: Any] {
        [
            "segments": speakers.enumerated().map { i, s in
                ["start": Double(i) * 10, "end": Double(i) * 10 + 5, "text": "line \(i)", "speaker": s]
            },
        ]
    }

    func test_second_visit_with_unchanged_files_measures_nothing() async throws {
        let dir = try tempDir()
        for stem in ["a", "b"] {
            try write(dir.appendingPathComponent("\(stem).json"), json: transcript(["Me", "Them"]))
        }
        let meetings = [meeting("a", in: dir), meeting("b", in: dir)]
        let projection = StatsProjection()

        var firstVisit: StatsLoader.Pass?
        await projection.reload(meetings: meetings, ownerLabel: "Me") { firstVisit = $0 }.value
        XCTAssertEqual(Set(firstVisit?.measured ?? []), ["a", "b"])

        // A rail switch destroys StatsView; the next visit is a new view over the same projection.
        var secondVisit: StatsLoader.Pass?
        await projection.reload(meetings: meetings, ownerLabel: "Me") { secondVisit = $0 }.value
        XCTAssertEqual(secondVisit?.measured, [], "no transcript is re-read on a second visit")
        XCTAssertEqual(secondVisit?.facts.compactMap(\.talk?.mineSec), [5, 5])
    }

    func test_overlay_change_remeasures_only_that_meeting() async throws {
        let dir = try tempDir()
        for stem in ["a", "b"] {
            try write(dir.appendingPathComponent("\(stem).json"), json: transcript(["speaker_0", "speaker_1"]))
        }
        let meetings = [meeting("a", in: dir), meeting("b", in: dir)]
        let projection = StatsProjection()
        await projection.reload(meetings: meetings, ownerLabel: "Me") { _ in }.value

        // An in-app rename writes only the speaker overlay, naming speaker_0 as the owner.
        let overlay = SpeakerLabelStore.path(stem: "b", in: dir)
        try write(overlay, json: ["labels": ["speaker_0": "Me"]])
        try setMtime(overlay, Date(timeIntervalSinceNow: -60))

        var after: StatsLoader.Pass?
        await projection.reload(meetings: meetings, ownerLabel: "Me") { after = $0 }.value
        XCTAssertEqual(after?.measured, ["b"])
        XCTAssertNil(after?.facts.first { $0.stem == "a" }?.talk, "no owner voice in a")
        XCTAssertEqual(after?.facts.first { $0.stem == "b" }?.talk?.mineSec, 5, "the rename counts at once")
    }

    func test_owner_label_change_drops_the_cache() async throws {
        let dir = try tempDir()
        for stem in ["a", "b"] {
            try write(dir.appendingPathComponent("\(stem).json"), json: transcript(["Me", "Them"]))
        }
        let meetings = [meeting("a", in: dir), meeting("b", in: dir)]
        let projection = StatsProjection()
        await projection.reload(meetings: meetings, ownerLabel: "Me") { _ in }.value

        var renamed: StatsLoader.Pass?
        await projection.reload(meetings: meetings, ownerLabel: "Them") { renamed = $0 }.value
        XCTAssertEqual(Set(renamed?.measured ?? []), ["a", "b"])
        XCTAssertEqual(renamed?.facts.compactMap(\.talk?.mineSec), [5, 5], "now measured as Them")
    }

    func test_a_cancelled_pass_keeps_what_it_measured() async throws {
        // The revision-burst case: a pass superseded part-way must not cost the next one its work.
        let dir = try tempDir()
        let meetings = [meeting("a", in: dir), meeting("b", in: dir)]
        let projection = StatsProjection { meeting, _ in
            // Stand in for a revision landing while "a" is being read.
            if meeting.stem == "a" { withUnsafeCurrentTask { $0?.cancel() } }
            return .talk(MeetingStats.Talk(mineSec: 1, theirsSec: 1, unattributedSec: 0))
        }
        var applied = 0
        await projection.reload(meetings: meetings, ownerLabel: "Me") { _ in applied += 1 }.value
        XCTAssertEqual(applied, 0, "a part-way pass is never shown")

        var next: StatsLoader.Pass?
        await projection.reload(meetings: meetings, ownerLabel: "Me") { next = $0 }.value
        XCTAssertEqual(next?.measured, ["b"], "a was kept from the cancelled pass")
        XCTAssertEqual(next?.facts.count, 2)
    }

    func test_a_revision_mid_pass_starts_from_what_the_superseded_pass_read() async throws {
        // The production ordering: the next reload arrives while the cold pass is still reading,
        // before it has delivered anything. Snapshotting the cache at that moment would start the
        // new pass empty and re-read "a".
        let dir = try tempDir()
        let meetings = [meeting("a", in: dir), meeting("b", in: dir)]
        let readingA = expectation(description: "first pass is reading a")
        readingA.assertForOverFulfill = false
        let release = DispatchSemaphore(value: 0)
        let projection = StatsProjection { meeting, _ in
            if meeting.stem == "a" {
                readingA.fulfill()
                // Bounded, so a regression fails the assertion below instead of hanging the suite.
                _ = release.wait(timeout: .now() + 2)
            }
            return .talk(MeetingStats.Talk(mineSec: 1, theirsSec: 1, unattributedSec: 0))
        }

        let first = projection.reload(meetings: meetings, ownerLabel: "Me") { _ in }
        await fulfillment(of: [readingA], timeout: 5)
        var second: StatsLoader.Pass?
        let next = projection.reload(meetings: meetings, ownerLabel: "Me") { second = $0 }
        release.signal()
        await first.value
        await next.value

        XCTAssertEqual(second?.measured, ["b"], "a came from the pass it superseded")
        XCTAssertEqual(second?.facts.count, 2)
    }

    func test_unreadable_transcript_is_not_cached() throws {
        let dir = try tempDir()
        try write(dir.appendingPathComponent("a.json"), "not json")
        let pass = StatsLoader.load(meetings: [meeting("a", in: dir)], ownerLabel: "Me")
        XCTAssertEqual(pass.measured, ["a"])
        XCTAssertTrue(pass.cache.stems.entries.isEmpty)
    }

    func test_speech_load_measures_what_the_full_load_measures() throws {
        // The light load skips corrections and embeddings; neither moves a line's time or speaker.
        let dir = try tempDir()
        try write(dir.appendingPathComponent("a.json"), json: transcript(["Me", "Them", "Me"]))
        _ = try TranscriptCorrectionStore.upsert(
            segmentIndex: 1, pipelineOriginal: "line 1", edited: "edited", stem: "a", in: dir
        )
        try write(SpeakerLabelStore.path(stem: "a", in: dir), json: ["labels": ["Them": "Bob"]])

        let full = try XCTUnwrap(TranscriptLoader.load(stem: "a", in: dir))
        let fromFull = MeetingStats.talk(segments: full.segments, overlay: full.speakerOverlay, ownerLabel: "Me")
        XCTAssertEqual(StatsLoader.read(meeting: meeting("a", in: dir), ownerLabel: "Me"), .talk(fromFull))
    }

    // MARK: - People

    func test_people_rereads_only_the_stem_whose_overlay_changed() throws {
        let dir = try tempDir()
        for stem in ["a", "b"] {
            let url = dir.appendingPathComponent("\(stem).summary.json")
            try write(url, json: summaryJSON(task: "x", attendees: ["speaker_0"]))
            try setMtime(url, Date(timeIntervalSinceNow: -3600))
        }
        let meetings = [meeting("a", in: dir, hasSummary: true), meeting("b", in: dir, hasSummary: true)]
        let first = PeopleLoader.load(meetings: meetings, roster: { [] })
        XCTAssertEqual(Set(first.read), ["a", "b"])

        let second = PeopleLoader.load(meetings: meetings, cache: first.cache, roster: { [] })
        XCTAssertEqual(second.read, [])

        let overlay = SpeakerLabelStore.path(stem: "a", in: dir)
        try write(overlay, json: ["labels": ["speaker_0": "Rana"]])
        let third = PeopleLoader.load(meetings: meetings, cache: second.cache, roster: { [] })
        XCTAssertEqual(third.read, ["a"])
        XCTAssertEqual(third.facts.first { $0.stem == "a" }?.people, ["Rana"])
    }

    // MARK: - Embeddings

    func test_one_embeddings_read_answers_both_values() throws {
        let dir = try tempDir()
        try write(dir.appendingPathComponent("a.json"), json: transcript(["THEM-A", "THEM-B"]))
        try write(dir.appendingPathComponent("a.embeddings.json"), json: [
            "embeddings": ["THEM-A": [0.1, 0.2], "THEM-B": [0.3]],
            "near_misses": ["THEM-B": "Rana", "": "x", "THEM-C": ""],
        ])

        let single = MeetingStore.embeddingsSidecar(stem: "a", in: dir)
        XCTAssertEqual(single.voiceprintLabels, ["THEM-A", "THEM-B"])
        XCTAssertEqual(single.nearMisses, ["THEM-B": "Rana"])
        // The two public readers and the transcript load agree with the single read.
        XCTAssertEqual(MeetingStore.voiceprintLabels(stem: "a", in: dir), single.voiceprintLabels)
        XCTAssertEqual(MeetingStore.nearMisses(stem: "a", in: dir), single.nearMisses)
        let loaded = try XCTUnwrap(TranscriptLoader.load(stem: "a", in: dir))
        XCTAssertEqual(loaded.voiceprintLabels, single.voiceprintLabels)
        XCTAssertEqual(loaded.nearMisses, single.nearMisses)
    }

    func test_embeddings_keys_stay_independent() {
        XCTAssertEqual(
            MeetingStore.embeddingsSidecar(from: ["near_misses": ["THEM-A": "Rana"]]),
            .init(voiceprintLabels: [], nearMisses: ["THEM-A": "Rana"])
        )
        XCTAssertEqual(
            MeetingStore.embeddingsSidecar(from: ["embeddings": ["THEM-A": [1.0]], "near_misses": "garbage"]),
            .init(voiceprintLabels: ["THEM-A"], nearMisses: [:])
        )
    }
}
