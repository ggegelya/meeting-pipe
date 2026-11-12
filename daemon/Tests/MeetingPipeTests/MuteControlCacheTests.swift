import XCTest
@testable import MeetingPipe
@testable import MeetingPipeCore

/// PERF18: the mute backstop's per-recording control cache. A fake Teams (windows by name, a
/// subrole and an optional mute button per window) with a lister, walker and reader that count
/// their calls, so each test pins how many cross-process reads a poll would make.
final class MuteControlCacheTests: XCTestCase {

    /// The fake meeting client. `windows` is what the lister returns; a window absent from
    /// `controls` has no mute button (the Calendar or chat window).
    final class FakeClient {
        var windows: [String] = []
        var subroles: [String: String] = [:]
        var controls: [String: (mute: String, hasLeave: Bool)] = [:]
        var states: [String: MuteLabels.State] = [:]
        var now: TimeInterval = 0

        private(set) var lists = 0
        private(set) var walksByWindow: [String: Int] = [:]
        private(set) var readsByButton: [String: Int] = [:]

        func makeCache(backstop: TimeInterval = 10) -> MuteControlCache<String, String> {
            MuteControlCache<String, String>(
                listWindows: { [unowned self] in self.lists += 1; return self.windows },
                subrole: { [unowned self] in self.subroles[$0] },
                walk: { [unowned self] window in
                    self.walksByWindow[window, default: 0] += 1
                    return self.controls[window]
                },
                read: { [unowned self] button in
                    self.readsByButton[button, default: 0] += 1
                    return self.states[button] ?? .unknown
                },
                now: { [unowned self] in self.now },
                backstopInterval: backstop
            )
        }

        /// The backgrounded call as the 2026-07-14 dump shows it, minus the panel: the full
        /// meeting window (mute + Leave) and the Calendar window (nothing).
        static func focusedCall() -> FakeClient {
            let client = FakeClient()
            client.windows = ["meeting", "calendar"]
            client.subroles = ["meeting": "AXStandardWindow", "calendar": "AXStandardWindow"]
            client.controls = ["meeting": (mute: "meeting.mute", hasLeave: true)]
            client.states = ["meeting.mute": .unmuted]
            return client
        }
    }

    /// Runs `count` polls one second apart, returning how many walked.
    @discardableResult
    private func poll(
        _ cache: MuteControlCache<String, String>, _ client: FakeClient, times count: Int
    ) -> [(states: [MuteLabels.State], fullWalk: Bool)] {
        (0..<count).map { _ in
            let result = cache.resolve()
            client.now += 1
            return result
        }
    }

    // MARK: - Steady state

    func test_tenSteadyPolls_walkOnce_listTenTimes_andReadTheCachedButtonTenTimes() {
        let client = FakeClient.focusedCall()
        let cache = client.makeCache()

        let results = poll(cache, client, times: 10)

        XCTAssertEqual(cache.fullWalks, 1)
        XCTAssertEqual(results.map(\.fullWalk), [true] + Array(repeating: false, count: 9))
        XCTAssertEqual(client.lists, 10)
        XCTAssertEqual(client.readsByButton["meeting.mute"], 10)
        XCTAssertEqual(client.walksByWindow["calendar"], 1, "the window with no mute button is walked once, not every second")
        XCTAssertEqual(results.map(\.states), Array(repeating: [.unmuted], count: 10))
    }

    func test_windowOrderChangeAlone_doesNotWalk() {
        // Teams reorders its windows on every focus change; the set is what matters.
        let client = FakeClient.focusedCall()
        let cache = client.makeCache()
        poll(cache, client, times: 1)

        client.windows = ["calendar", "meeting"]
        poll(cache, client, times: 3)

        XCTAssertEqual(cache.fullWalks, 1)
    }

    // MARK: - Window-set and subrole changes

    func test_aWindowAdded_walksEveryWindowOnThatPoll() {
        let client = FakeClient.focusedCall()
        let cache = client.makeCache()
        poll(cache, client, times: 3)

        client.windows.append("chat")
        client.subroles["chat"] = "AXStandardWindow"
        let result = cache.resolve()

        XCTAssertTrue(result.fullWalk)
        XCTAssertEqual(cache.fullWalks, 2)
        XCTAssertEqual(client.walksByWindow["chat"], 1)
        XCTAssertEqual(client.walksByWindow["meeting"], 2, "a set change re-walks every window, not only the new one")
        XCTAssertEqual(client.walksByWindow["calendar"], 2)
    }

    func test_aWindowRemoved_walksOnThatPoll_andDropsItsButton() {
        let client = FakeClient.focusedCall()
        client.windows.append("hub")
        client.subroles["hub"] = "AXStandardWindow"
        client.controls["hub"] = (mute: "hub.mute", hasLeave: false)
        client.states["hub.mute"] = .muted
        let cache = client.makeCache()
        poll(cache, client, times: 2)

        client.windows.removeAll { $0 == "hub" }
        let result = cache.resolve()

        XCTAssertTrue(result.fullWalk)
        XCTAssertEqual(result.states, [.unmuted])
        XCTAssertEqual(client.readsByButton["hub.mute"], nil, "the Leave scoping never read the hub's button")
    }

    func test_aSubroleChangeToSystemDialog_walks_andThePanelButtonIsTheOnlyOneRead() {
        // MIC10 part 1: Teams backgrounded, the compact call panel appears (here as an existing
        // window whose subrole flips) and the full meeting window's button freezes.
        let client = FakeClient.focusedCall()
        client.windows.append("panel")
        client.subroles["panel"] = "AXStandardWindow"
        client.controls["panel"] = (mute: "panel.mute", hasLeave: true)
        client.states["panel.mute"] = .muted
        let cache = client.makeCache()
        poll(cache, client, times: 2)
        let meetingReadsBefore = client.readsByButton["meeting.mute"] ?? 0
        let panelReadsBefore = client.readsByButton["panel.mute"] ?? 0

        client.subroles["panel"] = "AXSystemDialog"
        let result = cache.resolve()
        client.now += 1
        let next = cache.resolve()

        XCTAssertTrue(result.fullWalk)
        XCTAssertFalse(next.fullWalk)
        XCTAssertEqual(result.states, [.muted])
        XCTAssertEqual(next.states, [.muted])
        XCTAssertEqual(client.readsByButton["meeting.mute"], meetingReadsBefore, "the frozen full window is not read once the panel exists")
        XCTAssertEqual(client.readsByButton["panel.mute"], panelReadsBefore + 2)
    }

    // MARK: - Unknown reads

    func test_anUnknownRead_walksOnTheNextPoll_andNotAgainBeforeTheBackstop() {
        let client = FakeClient.focusedCall()
        let cache = client.makeCache(backstop: 10)
        poll(cache, client, times: 3)          // t = 0..2, one walk at t = 0

        client.states["meeting.mute"] = .unknown
        let results = poll(cache, client, times: 9) // t = 3..11

        // t = 3 reads unknown; t = 4 walks for it; t = 5..11 stay unknown with no walk (the
        // backstop from t = 4 is due at t = 14).
        XCTAssertEqual(results.map(\.fullWalk), [false, true, false, false, false, false, false, false, false])
        XCTAssertEqual(cache.fullWalks, 2)
    }

    func test_aPersistentUnknown_walksOnlyOnItsFirstPollAndAtTheBackstop() {
        // A label missing from MuteLabels.toml must not put the walk back at 1 Hz, nor at two
        // walks per backstop interval (a level trigger would add one right after every backstop).
        let client = FakeClient.focusedCall()
        client.states["meeting.mute"] = .unknown
        let cache = client.makeCache(backstop: 10)

        let results = poll(cache, client, times: 31) // t = 0..30

        let walkedAt = results.enumerated().filter { $0.element.fullWalk }.map(\.offset)
        XCTAssertEqual(walkedAt, [0, 1, 11, 21])
    }

    func test_aFailedRead_countsAsUnknown() {
        // A destroyed element reads an empty blob, which `MuteLabels.recognize` answers `.unknown`.
        let labels = MuteLabels(entries: [:])
        XCTAssertEqual(labels.recognize(app: "teams", locale: "en", title: nil, help: nil, description: nil), .unknown)
    }

    func test_aNewUnknownStreakWithinTheBackstopOfTheLastUnknownWalk_isThrottled() {
        let client = FakeClient.focusedCall()
        let cache = client.makeCache(backstop: 10)
        poll(cache, client, times: 1)                  // t = 0 walk
        client.states["meeting.mute"] = .unknown
        poll(cache, client, times: 2)                  // t = 1 unknown, t = 2 walk
        client.states["meeting.mute"] = .unmuted
        poll(cache, client, times: 1)                  // t = 3 known
        client.states["meeting.mute"] = .unknown
        let results = poll(cache, client, times: 3)    // t = 4..6

        XCTAssertEqual(results.map(\.fullWalk), [false, false, false])
        XCTAssertEqual(cache.fullWalks, 2)
    }

    // MARK: - Backstop

    func test_theBackstopWalks_afterItsIntervalWithNothingChanged() {
        let client = FakeClient.focusedCall()
        let cache = client.makeCache(backstop: 10)

        let results = poll(cache, client, times: 21) // t = 0..20

        let walkedAt = results.enumerated().filter { $0.element.fullWalk }.map(\.offset)
        XCTAssertEqual(walkedAt, [0, 10, 20])
    }

    func test_theBackstopFindsAButtonThatAppearsInAnExistingWindow() {
        let client = FakeClient.focusedCall()
        client.controls = [:]   // the meeting window has not rendered its controls yet
        let cache = client.makeCache(backstop: 10)
        let early = poll(cache, client, times: 10)
        XCTAssertTrue(early.allSatisfy { $0.states.isEmpty })

        client.controls = ["meeting": (mute: "meeting.mute", hasLeave: true)]
        let found = cache.resolve()

        XCTAssertTrue(found.fullWalk)
        XCTAssertEqual(found.states, [.unmuted])
    }

    // MARK: - Pure walk decision

    func test_walkReason_precedence() {
        typealias Cache = MuteControlCache<String, String>
        XCTAssertEqual(Cache.walkReason(hasWalked: false, windowsChanged: true, unknownWalkDue: true, sinceLastWalk: 99, backstopInterval: 10), .first)
        XCTAssertEqual(Cache.walkReason(hasWalked: true, windowsChanged: true, unknownWalkDue: true, sinceLastWalk: 99, backstopInterval: 10), .windowsChanged)
        XCTAssertEqual(Cache.walkReason(hasWalked: true, windowsChanged: false, unknownWalkDue: true, sinceLastWalk: 99, backstopInterval: 10), .unknownRead)
        XCTAssertEqual(Cache.walkReason(hasWalked: true, windowsChanged: false, unknownWalkDue: false, sinceLastWalk: 10, backstopInterval: 10), .backstop)
        XCTAssertNil(Cache.walkReason(hasWalked: true, windowsChanged: false, unknownWalkDue: false, sinceLastWalk: 9.9, backstopInterval: 10))
    }

    // MARK: - Through the watcher

    func test_theWatcherCountsFullWalks_andReportsThemWhenStopped() {
        let client = FakeClient.focusedCall()
        let cache = client.makeCache(backstop: 10)
        let log = RecordingEventLog()
        var pending: (() -> Void)?
        let watcher = MeetingAXWindowWatcher(
            pid: 4242,
            bundleID: "com.microsoft.teams2",
            catalogue: MuteLabels(entries: [:]),
            eventLog: log,
            onMuteEvent: { _ in },
            scheduler: { _, action in pending = action; return { pending = nil } },
            cachedResolver: {
                let result = cache.resolve()
                client.now += 1
                return result
            },
            localeResolver: { "en" }
        )

        watcher.start()                       // poll 1, t = 0
        for _ in 0..<11 {                     // polls 2..12, t = 1..11
            let next = pending
            pending = nil
            next?()
        }
        watcher.stop()

        let stopped = log.entries.filter { $0.action == "mute_poller_stopped" }
        XCTAssertEqual(stopped.count, 1, "the stop() inside start() logs nothing")
        XCTAssertEqual(stopped.first?.category, "micgate")
        XCTAssertEqual(stopped.first?.attributes["polls"], "12")
        XCTAssertEqual(stopped.first?.attributes["full_walks"], "2")
        XCTAssertEqual(stopped.first?.attributes["bundle_id"], "com.microsoft.teams2")

        watcher.stop()
        XCTAssertEqual(log.entries.filter { $0.action == "mute_poller_stopped" }.count, 1, "a second stop logs nothing")
    }
}
