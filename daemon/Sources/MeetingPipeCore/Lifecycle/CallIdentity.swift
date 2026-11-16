import Foundation

/// END28: one read of the window that holds the call's Leave control. `windowID` changes exactly
/// when the window element does (`AXLeaveButtonSignal` compares elements with `CFEqual`), so a split
/// can tell "another window" from "the same window retitled" without comparing any label.
/// `serial` numbers the AX reads: the host ticks faster than the Leave signal's backed-off poll
/// reads, so one cached read is seen several times and must count once. Zero means unnumbered.
public struct CallWindowRead: Equatable, Sendable {
    public let windowID: UInt
    public let title: String?
    public let subrole: String?
    public let serial: UInt64

    public init(windowID: UInt, title: String?, subrole: String?, serial: UInt64 = 0) {
        self.windowID = windowID
        self.title = title
        self.subrole = subrole
        self.serial = serial
    }

    /// Same window, same title: the same call identity, whichever read it came from.
    func sameIdentity(as other: CallWindowRead) -> Bool {
        windowID == other.windowID && title == other.title
    }
}

/// END28: which call a recording is of, and when it changed to another one. A quick switch from
/// one Teams call to another makes every app-level signal live again within seconds, so END17's
/// hold reverts and the second call used to record into the first call's stem
/// (`20261112-172307`). The call window's title is the meeting subject, set by the organiser, so it
/// carries the call's identity where no app-level signal does.
///
/// Pure and clocked by its caller, so the rule is pinned without AX. Three rules keep a false split
/// (which chops a live meeting) rarer than the missed one it fixes:
/// - **A split needs a different window and a different title.** The same window retitled (the
///   main window navigating, an organiser renaming the meeting, a 1:1 becoming a group call) is
///   not another call. A recurring meeting rejoined under the same title is not a split either.
/// - **The new identity has to hold.** At least `confirmReads` consecutive AX reads of it, the first
///   and last at least `confirmSpan` apart. A nil read or a third value starts the count again;
///   reading the recorded identity clears it.
/// - **No identity is no evidence.** A nil read (no Leave window, an empty title, the app's own
///   name, the floating call panel) never splits and never clears what was recorded; adoption
///   waits while a hold is open, so a hold's first doubt cannot become the recording's identity.
///
/// It is a split signal only: an unchanged title never vetoes an end or reverts a hold.
public struct CallIdentityTracker: Equatable {

    public enum Action: Equatable {
        case none
        case adopted(CallWindowRead)
        case split(from: CallWindowRead, to: CallWindowRead)
    }

    public static let confirmReads = 2
    public static let confirmSpan: TimeInterval = 4
    /// `AXSystemDialog`, the subrole of Teams' floating compact call panel, whose title is not the
    /// meeting's (`MeetingAXHandleBuilder.isCallPanel`).
    public static let callPanelSubrole = "AXSystemDialog"

    public private(set) var identity: CallWindowRead?
    private var pending: CallWindowRead?
    private var pendingFirstAt: Date?
    private var pendingCount = 0
    /// The serial of the last numbered read observed, so a cached read seen again counts once.
    private var lastSerial: UInt64 = 0

    public init(identity: CallWindowRead? = nil) {
        self.identity = identity
    }

    /// The read with everything that is not a call identity mapped to nil.
    static func usable(_ read: CallWindowRead?, appName: String?) -> CallWindowRead? {
        guard let read, read.subrole != callPanelSubrole else { return nil }
        guard let title = read.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        if let appName, title.caseInsensitiveCompare(appName) == .orderedSame { return nil }
        return CallWindowRead(windowID: read.windowID, title: title, subrole: read.subrole, serial: read.serial)
    }

    public mutating func observe(_ raw: CallWindowRead?, appName: String?, holdOpen: Bool, at now: Date) -> Action {
        if let raw, raw.serial != 0 {
            if raw.serial == lastSerial { return .none }
            lastSerial = raw.serial
        }
        guard let read = Self.usable(raw, appName: appName) else {
            clearPending()
            return .none
        }
        guard let current = identity else {
            if holdOpen { return .none }
            identity = read
            return .adopted(read)
        }
        if read.title == current.title {
            // The same call, possibly in a recreated window: follow the window so a later switch
            // is measured against the one actually holding the call.
            identity = read
            clearPending()
            return .none
        }
        if read.windowID == current.windowID {
            clearPending()
            return .none
        }
        if let pending, let firstAt = pendingFirstAt, pending.sameIdentity(as: read) {
            pendingCount += 1
            if pendingCount >= Self.confirmReads, now.timeIntervalSince(firstAt) >= Self.confirmSpan {
                identity = read
                clearPending()
                return .split(from: current, to: read)
            }
            return .none
        }
        pending = read
        pendingFirstAt = now
        pendingCount = 1
        return .none
    }

    private mutating func clearPending() {
        pending = nil
        pendingFirstAt = nil
        pendingCount = 0
    }
}
