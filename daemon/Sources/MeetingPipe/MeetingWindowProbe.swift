import AppKit
import ApplicationServices
import Foundation

/// Stable handle to the AX window that owns the in-flight meeting,
/// captured at `.started` time. Owning the specific window lets the
/// end-detection probe ask "is THIS window still a meeting" instead
/// of "do any of the app's windows look meeting-shaped" — the latter
/// pattern is the one Teams broke (any open chat / channel window's
/// title passes the permissive recognizer, so the OR-across-windows
/// probe never goes false → end never fires).
struct MeetingWindowHandle {
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String
}

/// Per-app meeting-window probe. Three responsibilities:
///
///  1. At `.started`, pick the specific AXUIElement that represents
///     the meeting window for the recording's source app.
///  2. While recording, answer "is this still the meeting?" by
///     checking the element's validity AND descending its subtree for
///     the app's Leave / Hangup control. Either signal flipping →
///     end. The OR makes us robust both to the window being closed
///     outright and to Teams' habit of repurposing the window into a
///     post-call surface that keeps a non-chrome title.
///  3. Surface a pure-string predicate (`isLeaveButton`) for tests
///     that don't want to drive AX.
///
/// All AX work in this enum is safe to call from any thread:
/// `AXUIElementCopyAttributeValue` / `AXUIElementCreateApplication`
/// are documented thread-safe, and the per-app extractors operate on
/// the immutable string fields they read.
enum MeetingWindowProbe {

    /// Capture the meeting window for this source. Returns nil when:
    ///   - AX permission is missing (the probe falls back to the
    ///     legacy title-scan in Detector),
    ///   - the source app is no longer running,
    ///   - no window matches the per-app shape (rare but possible —
    ///     the user can fire `.started` from manual ⌃⌥M even when no
    ///     meeting window exists yet).
    ///
    /// Browsers are explicitly out of scope: their meeting window
    /// surface is a Chromium / WebKit-rendered tab, and the call
    /// controls aren't exposed as native AX elements at all. The tab-
    /// strip probe in Detector already covers that case.
    static func capture(source: AppSource) -> MeetingWindowHandle? {
        guard source.kind == .native, AXIsProcessTrusted() else { return nil }
        guard let pid = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == source.bundleID })?.processIdentifier else {
            return nil
        }
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }
        // Pick the FIRST window whose title recognises as a meeting
        // window under the existing per-app recogniser. Teams etc.
        // may have multiple meeting windows (rare — breakout rooms),
        // but the first one is good enough — when it closes, the
        // user is no longer in the original call.
        for window in windows {
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let title = titleRef as? String, !title.isEmpty else { continue }
            if Detector.isActiveMeetingWindow(bundleID: source.bundleID, kind: source.kind, title: title) {
                return MeetingWindowHandle(element: window, pid: pid, bundleID: source.bundleID)
            }
        }
        return nil
    }

    enum Status: Equatable {
        /// Window is alive, leave control present (or unknown-shape
        /// app whose probe can't decide). Composer should keep
        /// recording.
        case stillOpen
        /// AX attribute access returned `kAXErrorInvalidUIElement` /
        /// `kAXErrorCannotComplete` — the underlying NSWindow is
        /// gone. Strongest possible end signal.
        case closed
        /// Window alive, but a full subtree walk found no Leave /
        /// Hang-up button. The meeting view has been repurposed
        /// (Teams' "post-call summary" surface, Zoom's "Meeting
        /// ended" pane).
        case leftMeeting
        /// Transient AX failure mid-traversal. Caller should treat
        /// this as `stillOpen` for the round so a one-off AX hiccup
        /// doesn't cut a recording.
        case inconclusive
    }

    /// Evaluate the current state of the captured window. Each call
    /// is independent — no state cached between rounds — so a
    /// previously-`closed` handle that magically becomes valid again
    /// would still re-recognise (a useful property for tests).
    static func evaluate(_ handle: MeetingWindowHandle) -> Status {
        // Validity probe: ask for the title. An invalid element
        // returns `.invalidUIElement` / `.cannotComplete` /
        // `.notImplemented`. Reading the title costs a single AX RPC
        // and doubles as the existence check.
        var titleRef: CFTypeRef?
        let titleErr = AXUIElementCopyAttributeValue(
            handle.element, kAXTitleAttribute as CFString, &titleRef
        )
        switch titleErr {
        case .success:
            break
        case .invalidUIElement, .cannotComplete, .notImplemented:
            return .closed
        default:
            // .noValue / .attributeUnsupported / etc. — the element
            // is alive but the attribute didn't answer. Treat as
            // inconclusive (do not end).
            return .inconclusive
        }
        // Subtree walk for the per-app Leave button. If we find one,
        // we're still in the meeting. The walk is bounded by
        // `maxDepth` and bails early on first match.
        let foundLeave = findLeaveButton(
            in: handle.element,
            bundleID: handle.bundleID,
            depth: 0
        )
        switch foundLeave {
        case .found:
            return .stillOpen
        case .notFound:
            return .leftMeeting
        case .axFailure:
            return .inconclusive
        }
    }

    /// Pure string predicate matching the Leave / Hangup control for
    /// each known meeting client. Per-bundle so a Slack-style "Leave
    /// huddle" doesn't trigger Teams' "Leave call" check or vice
    /// versa. All three input fields can be nil — AX may expose only
    /// one of title / help / description depending on app version,
    /// and the meeting-client engineers move them around between
    /// updates.
    ///
    /// Inputs are matched case-insensitively. Returns true on a
    /// positive match. False both for "not a leave button" and for
    /// "all nil inputs", since a button with no readable surface
    /// can't be confirmed to be Leave.
    static func isLeaveButton(
        bundleID: String,
        title: String?,
        help: String?,
        description: String?
    ) -> Bool {
        let blob = [title, help, description]
            .compactMap { $0?.lowercased() }
            .joined(separator: " | ")
        if blob.isEmpty { return false }

        switch bundleID {
        case "us.zoom.xos":
            // Zoom: the call control reads "Leave" (host sees "End"
            // as a sibling option in a dropdown — we accept either).
            return blob.contains("leave") || blob.contains("end meeting")

        case "com.microsoft.teams2", "com.microsoft.teams":
            // Teams: usually "Leave" / "Hang up" / "Leave call".
            // The help/tooltip carries "Leave (Ctrl+Shift+H)" or
            // similar; match on the verb so a localised hotkey hint
            // doesn't matter.
            return blob.contains("leave")
                || blob.contains("hang up")
                || blob.contains("hangup")

        case "com.cisco.webexmeetingsapp":
            // Webex: "Leave meeting" / "End meeting" / "End"
            return blob.contains("leave meeting")
                || blob.contains("end meeting")
                || blob == "end"
                || blob.contains("leave")

        case "com.tinyspeck.slackmacgap":
            return blob.contains("leave huddle")
                || blob.contains("leave call")
                || blob.contains("end huddle")

        case "com.skype.skype":
            return blob.contains("end call")
                || blob.contains("hang up")

        case "com.google.meet":
            return blob.contains("leave call")
                || blob.contains("leave meeting")

        default:
            return false
        }
    }

    // MARK: - Subtree walk

    /// Bounded recursive walk for the Leave button. Mirrors
    /// `Detector.findTabTitles` in shape; bottoms out early on a
    /// positive hit. `maxDepth` is generous because Teams nests
    /// controls deeper than Zoom — 12 covers every native client
    /// inspected so far without runaway cost on edge layouts.
    private static let maxDepth = 12

    private enum SubtreeResult {
        case found
        case notFound
        case axFailure
    }

    private static func findLeaveButton(
        in element: AXUIElement,
        bundleID: String,
        depth: Int
    ) -> SubtreeResult {
        if depth > maxDepth { return .notFound }

        // Role + title/help/description probe for the current
        // element. The leave control is always an AXButton in every
        // app I've inspected — so we early-out on role first to
        // avoid an attribute fetch on every container element.
        var roleRef: CFTypeRef?
        let roleErr = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleErr == .success) ? (roleRef as? String) : nil
        let isButton = role == (kAXButtonRole as String)

        if isButton {
            let title = copyStringAttribute(element, kAXTitleAttribute)
            let help = copyStringAttribute(element, kAXHelpAttribute)
            let desc = copyStringAttribute(element, kAXDescriptionAttribute)
            if isLeaveButton(bundleID: bundleID, title: title, help: help, description: desc) {
                return .found
            }
        }

        // Children. A `cannotComplete` here while the OUTER element
        // is still valid (we already validated it via `evaluate`)
        // typically means a child died mid-traversal — surface as
        // axFailure so the caller treats this round as inconclusive
        // rather than `leftMeeting`.
        var childrenRef: CFTypeRef?
        let childrenErr = AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &childrenRef
        )
        if childrenErr == .cannotComplete {
            return .axFailure
        }
        guard childrenErr == .success,
              let children = childrenRef as? [AXUIElement] else {
            return .notFound
        }
        var sawFailure = false
        for child in children {
            switch findLeaveButton(in: child, bundleID: bundleID, depth: depth + 1) {
            case .found: return .found
            case .axFailure: sawFailure = true
            case .notFound: continue
            }
        }
        return sawFailure ? .axFailure : .notFound
    }

    private static func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard err == .success else { return nil }
        return ref as? String
    }
}
