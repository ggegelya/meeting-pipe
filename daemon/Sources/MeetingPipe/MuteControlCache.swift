import ApplicationServices
import Foundation
import MeetingPipeCore

/// The live mute control(s) of one recording, remembered between `MeetingAXWindowWatcher` polls
/// so the 1 Hz backstop stops re-walking every window of the meeting client every second (PERF18).
///
/// Before this, each poll ran `MeetingAXHandleBuilder.findMeetingWindowMuteButtons`: a mute DFS
/// of every window plus a Leave DFS of each window holding a mute button. The window with no
/// mute button (the Calendar or chat window Teams keeps open through every call) is the expensive
/// one, because nothing stops its DFS early: it runs to the end of its tree or the 4000-node
/// budget, serviced on Teams' main thread during the call and queued on the serial `axWalkQueue`
/// that the end-rescue Leave walk shares. Now a poll lists the windows (one read), reads each
/// window's subrole (one read each) and, while neither has changed, reads only the cached buttons.
///
/// When it walks again, every window, never only the new ones (the cache is never treated as
/// complete across a window-set change):
/// - on the first poll;
/// - when the window set or any window's subrole changes. Teams creates the compact call panel
///   (the one `AXSystemDialog`) as it is backgrounded and destroys it again when focused
///   (MIC10 part 1), so this is the change that matters most. Compared as a set, not in order,
///   because Teams reorders its windows on every focus change;
/// - on the poll after a cached button starts reading `.unknown` (a destroyed element or a
///   failed read lands there too, because an empty label blob recognises as `.unknown`), at most
///   once per `defaultBackstopInterval` and only on the streak's first unknown poll, so a label
///   missing from `MuteLabels.toml` cannot put the walk back at 1 Hz;
/// - every `defaultBackstopInterval`, so a window that gains a mute button without any
///   window-set change (the meeting window rendering its controls late) is still found.
///
/// The picking rule stays `MeetingAXHandleBuilder.scopeToLiveControl`, applied to the cached
/// entries on every poll, and only the scoped buttons are read.
///
/// Threading: none of its own. In production it lives inside the watcher's default resolver,
/// which only ever runs on `MeetingSessionController.axWalkQueue`, so it is confined there and
/// needs no lock. Generic over the window and button types so tests drive it with plain values
/// and counting fakes; `live(axApp:bundleID:catalogue:)` is the AX-backed instance.
final class MuteControlCache<Window: Hashable, Button> {

    /// Why a poll walked every window. Pure output of `walkReason`, kept for the tests.
    enum WalkReason: Equatable {
        case first
        case windowsChanged
        case unknownRead
        case backstop
    }

    /// The backstop interval. 10 s, the low end of the spec's 10 to 15 s: it is the longest a
    /// mute control that appears inside an existing window can go unseen (it was about 1 s when
    /// every poll walked), and it still cuts the full walks to about one poll in ten. The blind
    /// clear (three polls) and the VAD contradiction cover a missing control meanwhile, and the
    /// primary `AXMuteButtonProbe` is unaffected. Computed because a generic type cannot hold a
    /// static stored property.
    static var defaultBackstopInterval: TimeInterval { 10 }

    private let listWindows: () -> [Window]
    private let subrole: (Window) -> String?
    private let walk: (Window) -> (mute: Button, hasLeave: Bool)?
    private let read: (Button) -> MuteLabels.State
    private let isCallPanel: (String?) -> Bool
    private let now: () -> TimeInterval
    private let backstopInterval: TimeInterval

    /// The window set and subroles the cached entries were walked against; nil until the first walk.
    private var walkedWindows: [Window: String?]?
    /// One entry per window that had a mute button at the last walk, in listed order. A window
    /// with none is remembered only by being in `walkedWindows`, which is what keeps it unwalked.
    private var entries: [(value: Button, isCallPanel: Bool, hasLeave: Bool)] = []
    private var lastWalkAt: TimeInterval = 0
    private var lastUnknownWalkAt: TimeInterval?
    private var previousPollReadUnknown = false
    private var unknownWalkDue = false

    /// Full walks run so far. Read only on the confining queue (the watcher learns of each walk
    /// from `resolve`'s return value instead).
    private(set) var fullWalks = 0

    init(
        listWindows: @escaping () -> [Window],
        subrole: @escaping (Window) -> String?,
        walk: @escaping (Window) -> (mute: Button, hasLeave: Bool)?,
        read: @escaping (Button) -> MuteLabels.State,
        isCallPanel: @escaping (String?) -> Bool = MeetingAXHandleBuilder.isCallPanel(subrole:),
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        backstopInterval: TimeInterval = MuteControlCache.defaultBackstopInterval
    ) {
        self.listWindows = listWindows
        self.subrole = subrole
        self.walk = walk
        self.read = read
        self.isCallPanel = isCallPanel
        self.now = now
        self.backstopInterval = backstopInterval
    }

    /// One poll: list the windows, read their subroles, walk every window if `walkReason` says
    /// so, then read the scoped buttons. Returns the readings and whether this poll walked.
    func resolve() -> (states: [MuteLabels.State], fullWalk: Bool) {
        let t = now()
        let listed = listWindows()
        var current: [Window: String?] = [:]
        for window in listed {
            current.updateValue(subrole(window), forKey: window)
        }

        let reason = Self.walkReason(
            hasWalked: walkedWindows != nil,
            windowsChanged: walkedWindows.map { $0 != current } ?? false,
            unknownWalkDue: unknownWalkDue,
            sinceLastWalk: t - lastWalkAt,
            backstopInterval: backstopInterval
        )
        if let reason = reason {
            entries = listed.compactMap { window in
                guard let control = walk(window) else { return nil }
                let role = current[window] ?? nil
                return (control.mute, isCallPanel(role), control.hasLeave)
            }
            walkedWindows = current
            lastWalkAt = t
            fullWalks += 1
            // Any walk satisfies a pending unknown re-walk; only an unknown-driven one starts its throttle.
            unknownWalkDue = false
            if reason == .unknownRead { lastUnknownWalkAt = t }
        }

        let states = MeetingAXHandleBuilder.scopeToLiveControl(entries).map(read)

        // Edge-triggered: only the first unknown poll of a streak asks for a walk, and not within
        // a backstop interval of the last one it asked for. A level trigger would add a walk one
        // poll after every backstop walk for as long as the label stays unrecognised.
        let readUnknown = states.contains(.unknown)
        if readUnknown && !previousPollReadUnknown {
            let throttled = lastUnknownWalkAt.map { t - $0 < backstopInterval } ?? false
            if !throttled { unknownWalkDue = true }
        }
        previousPollReadUnknown = readUnknown

        return (states, reason != nil)
    }

    /// Whether this poll walks every window, and why. Pure, so the precedence is pinned directly.
    static func walkReason(
        hasWalked: Bool,
        windowsChanged: Bool,
        unknownWalkDue: Bool,
        sinceLastWalk: TimeInterval,
        backstopInterval: TimeInterval
    ) -> WalkReason? {
        if !hasWalked { return .first }
        if windowsChanged { return .windowsChanged }
        if unknownWalkDue { return .unknownRead }
        if sinceLastWalk >= backstopInterval { return .backstop }
        return nil
    }
}

extension MuteControlCache where Window == AXUIElement, Button == AXUIElement {
    /// The AX-backed cache for one recording's meeting client. Nil for a bundle with no entry in
    /// `MeetingAXHandleBuilder.appNameByBundle`, which never had a mute button to find.
    static func live(
        axApp: AXUIElement,
        bundleID: String,
        catalogue: MuteLabels
    ) -> MuteControlCache<AXUIElement, AXUIElement>? {
        guard let app = MeetingAXHandleBuilder.appNameByBundle[bundleID] else { return nil }
        return MuteControlCache(
            listWindows: { MeetingAXHandleBuilder.allWindows(of: axApp) },
            subrole: { MeetingAXHandleBuilder.subrole(of: $0) },
            walk: { window in
                MeetingAXHandleBuilder.meetingWindowControl(
                    in: window, app: app, bundleID: bundleID, catalogue: catalogue
                )
            },
            read: { button in
                let blob = AXMuteButtonProbe.defaultProbe(button)
                return catalogue.recognize(
                    app: app, locale: AXMuteButtonProbe.defaultLocaleResolver(),
                    title: blob.title, help: blob.help, description: blob.description
                )
            }
        )
    }
}
