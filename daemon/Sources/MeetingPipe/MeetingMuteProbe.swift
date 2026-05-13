import ApplicationServices
import Foundation

/// Per-app probe for the meeting client's current mute state.
///
/// Mirrors `MeetingWindowProbe` in shape: a pure string predicate that
/// inspects an accessibility button's title/help/description plus a
/// bounded AX subtree walk that finds the relevant button on a captured
/// meeting window. Lifted out so the Coordinator can poll mute state
/// every second during recording without colliding with the leave-button
/// probe and so tests can pin the per-app matchers without driving AX.
///
/// Why this exists: `AVAudioEngine.inputNode` taps the OS-level
/// microphone, which is independent of any meeting client's mute UI.
/// Without this, meeting-pipe captures the user's voice into `mic.wav`
/// even when the user has muted themselves in Teams / Zoom / etc., and
/// the transcript ends up including side conversations the user
/// explicitly excluded from the meeting record.
///
/// Encoding convention for the matchers:
///   - The visible button on every supported client toggles between an
///     "I'm muted, click to Unmute" label and an "I'm unmuted, click to
///     Mute" label. We treat "Unmute" as evidence the user is currently
///     muted (because that's the action they would take to leave the
///     muted state). "Mute" means currently unmuted.
///   - Both `title` and the help/description fall through to the same
///     predicate. Teams in particular routinely surfaces the verb only
///     in `AXHelp` with a blank `AXTitle` when the toolbar is
///     collapsed (same shape as the leave-button matcher).
///   - Unrecognised text returns `.unknown`. The caller treats unknown
///     as "don't change pause state" so an AX hiccup or a relabeled
///     button doesn't whipsaw the recorder.
enum MeetingMuteProbe {

    /// Result of one round of probing.
    enum State: Equatable {
        /// User is currently muted in the meeting client. Recorder
        /// should drop mic frames.
        case muted
        /// User is currently unmuted. Recorder should write mic frames.
        case unmuted
        /// AX walk produced no recognisable mute button (transient
        /// failure, unsupported app, the mute control is offscreen, the
        /// labels are localised in a language we don't match yet). Caller
        /// should keep the previous pause state.
        case unknown
    }

    /// Pure string predicate. All three fields can be nil — AX may
    /// expose only one of title / help / description depending on app
    /// version. Inputs matched case-insensitively. Returns `.unknown`
    /// for any blob that doesn't carry a clear mute / unmute verb so
    /// the AX walk can keep looking for a more authoritative match
    /// elsewhere in the subtree.
    static func recognize(
        bundleID: String,
        title: String?,
        help: String?,
        description: String?
    ) -> State {
        let blob = [title, help, description]
            .compactMap { $0?.lowercased() }
            .joined(separator: " | ")
        if blob.isEmpty { return .unknown }

        switch bundleID {
        case "com.microsoft.teams2", "com.microsoft.teams",
             "us.zoom.xos",
             "com.tinyspeck.slackmacgap":
            // The mute toggle on every supported client labels itself
            // either with an action verb ("Mute" / "Unmute") or a
            // status string ("Mic muted" / "Microphone is unmuted").
            // Disambiguate carefully:
            //   1. The status-phrase forms are unambiguous and most
            //      specific — check them first.
            //   2. The action-verb form: "unmute" is also a substring
            //      of "unmuted", so we can't naively check
            //      `.contains("unmute")` first. After the status
            //      phrases are filtered out, any remaining "unmute" is
            //      the action verb → currently muted; "mute" alone is
            //      the action verb → currently unmuted.
            if blob.contains("mic unmuted")
                || blob.contains("microphone unmuted")
                || blob.contains("microphone is unmuted") {
                return .unmuted
            }
            if blob.contains("mic muted")
                || blob.contains("microphone muted")
                || blob.contains("microphone is muted") {
                return .muted
            }
            if blob.contains("unmute") { return .muted }
            if blob.contains("mute") { return .unmuted }
            return .unknown

        default:
            return .unknown
        }
    }

    /// Walk the captured meeting window's AX subtree looking for a
    /// button whose label encodes mute state. Same bounded-depth
    /// strategy as `MeetingWindowProbe.findLeaveButton` so the cost
    /// stays predictable during a 1 s poll. Returns `.unknown` when:
    ///   - AX permission is missing,
    ///   - the underlying NSWindow is gone (probe shouldn't be running
    ///     in that case — the leave-button probe would already have
    ///     fired `.closed` — but we guard defensively),
    ///   - no recognisable mute control was found in the subtree.
    static func evaluate(_ handle: MeetingWindowHandle) -> State {
        // Validity probe: a dead element shouldn't be polled. Cheap RPC.
        var titleRef: CFTypeRef?
        let titleErr = AXUIElementCopyAttributeValue(
            handle.element, kAXTitleAttribute as CFString, &titleRef
        )
        switch titleErr {
        case .success, .noValue, .attributeUnsupported:
            break
        case .invalidUIElement, .cannotComplete, .notImplemented:
            return .unknown
        default:
            return .unknown
        }
        return walk(in: handle.element, bundleID: handle.bundleID, depth: 0)
    }

    // MARK: - Subtree walk

    /// Mirrors `MeetingWindowProbe.maxDepth`. Same client trees, same
    /// nesting characteristics.
    private static let maxDepth = 12

    private static func walk(
        in element: AXUIElement,
        bundleID: String,
        depth: Int
    ) -> State {
        if depth > maxDepth { return .unknown }

        // Match buttons only. The mute toggle on every supported client
        // is an `AXButton` (or a checkbox in older Teams builds — match
        // checkbox too because the predicate is text-based and harmless
        // on non-mute checkboxes).
        var roleRef: CFTypeRef?
        let roleErr = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleErr == .success) ? (roleRef as? String) : nil
        let isCandidate =
            role == (kAXButtonRole as String)
            || role == (kAXCheckBoxRole as String)

        if isCandidate {
            let title = copyStringAttribute(element, kAXTitleAttribute)
            let help = copyStringAttribute(element, kAXHelpAttribute)
            let desc = copyStringAttribute(element, kAXDescriptionAttribute)
            let recognised = recognize(
                bundleID: bundleID,
                title: title,
                help: help,
                description: desc
            )
            if recognised != .unknown {
                return recognised
            }
        }

        var childrenRef: CFTypeRef?
        let childrenErr = AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &childrenRef
        )
        guard childrenErr == .success,
              let children = childrenRef as? [AXUIElement] else {
            return .unknown
        }
        for child in children {
            let result = walk(in: child, bundleID: bundleID, depth: depth + 1)
            if result != .unknown { return result }
        }
        return .unknown
    }

    private static func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard err == .success else { return nil }
        return ref as? String
    }
}
