import AppKit
import ApplicationServices
import Foundation
import MeetingPipeCore

/// One-time AX walk per meeting that resolves the Leave button and the
/// Mute button for the matched app, packaged into the handles that
/// `MeetingLifecycleCoordinator.engage` and `MicGate.start` expect.
///
/// The walk runs once at meeting-start (per spec). Subsequent verdict
/// changes flow through observer notifications + 1 Hz health polls on
/// the shared buses; the tree itself is not re-walked.
///
/// Browser-hosted meetings get an empty handle: `WKWebView` does not
/// expose call controls as AX elements, so the lifecycle adapter
/// falls back to ShareableContent + window-title signals and MicGate
/// falls through to HAL VAD + RMS only.
enum MeetingAXHandleBuilder {

    struct Handles {
        let lifecycle: LifecycleAdapterHandle
        let micGate: MicGateAdapterHandle
        let context: MeetingLifecycleContext
    }

    /// Maps bundle ID to the `MuteLabels` short app name. The
    /// `MeetingPipeCore` adapters use these names to look up their
    /// per-locale labels.
    static let appNameByBundle: [String: String] = [
        "com.microsoft.teams2": "teams",
        "com.microsoft.teams": "teams",
        "us.zoom.xos": "zoom",
        "com.tinyspeck.slackmacgap": "slack",
        "com.cisco.webexmeetingsapp": "webex",
        "com.cisco.spark": "webex",
    ]

    /// Build the handles for a recording about to start. Returns nil
    /// when the app's PID can't be resolved (caller falls through to a
    /// degraded path).
    static func build(source: AppSource, catalogue: MuteLabels) -> Handles? {
        guard let pid = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == source.bundleID })?
            .processIdentifier else {
            return nil
        }
        let kind: MeetingLifecycleContext.Kind = (source.kind == .browser) ? .browser : .native
        let context = MeetingLifecycleContext(
            bundleID: source.bundleID,
            kind: kind,
            pid: pid,
            title: source.meetingTitle
        )

        // Browsers have no useful AX surface for call controls. Return
        // empty handles; the adapter relies on ShareableContent +
        // window-title signals and MicGate operates on HAL + RMS only.
        if kind == .browser {
            emitDiagnostic(source: source, axTrusted: nil, windowCount: 0,
                           foundLeave: false, foundMute: false)
            return Handles(
                lifecycle: LifecycleAdapterHandle(),
                micGate: MicGateAdapterHandle(),
                context: context
            )
        }

        let axTrusted = AXIsProcessTrusted()
        guard axTrusted else {
            emitDiagnostic(source: source, axTrusted: false, windowCount: 0,
                           foundLeave: false, foundMute: false)
            return Handles(
                lifecycle: LifecycleAdapterHandle(),
                micGate: MicGateAdapterHandle(),
                context: context
            )
        }

        let axApp = AXUIElementCreateApplication(pid)
        let allWindows = listWindows(axApp: axApp)
        let meetingWindow = pickMeetingWindow(windows: allWindows)
        let app = appNameByBundle[source.bundleID]

        // Search every window for leave + mute buttons. First match
        // per category wins. The picked meeting window is still used
        // for the lifecycle adapter's `meetingWindow` field, but
        // button discovery is decoupled because the AX tree's window
        // order isn't always [meeting, chat] (Teams ships both and
        // the chat window is what the title-first picker grabs;
        // searching every window finds the mute / leave buttons
        // even when the picker grabs the wrong window).
        var leave: AXUIElement?
        var mute: AXUIElement?
        for w in allWindows {
            if leave == nil {
                leave = findButton(in: w, depth: 0) { el in
                    matchesLeave(bundleID: source.bundleID, element: el)
                }
            }
            if mute == nil, let app = app {
                mute = findButton(in: w, depth: 0) { el in
                    matchesMute(app: app, catalogue: catalogue, element: el)
                }
            }
            if leave != nil && mute != nil { break }
        }

        emitDiagnostic(
            source: source,
            axTrusted: true,
            windowCount: allWindows.count,
            foundLeave: leave != nil,
            foundMute: mute != nil
        )

        return Handles(
            lifecycle: LifecycleAdapterHandle(leaveButton: leave, meetingWindow: meetingWindow),
            micGate: MicGateAdapterHandle(muteButton: mute),
            context: context
        )
    }

    // MARK: - Private

    /// Depth ceiling for the per-window button walk. 18 is empirically
    /// generous for Teams' nested toolbar shells (the old 12-level
    /// ceiling occasionally missed buttons in deeply-nested call
    /// controls); the walk is bounded by AX query latency, not by
    /// total nodes, so a deeper ceiling is cheap.
    private static let maxDepth = 18

    private static func listWindows(axApp: AXUIElement) -> [AXUIElement] {
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return []
        }
        return windows
    }

    private static func pickMeetingWindow(windows: [AXUIElement]) -> AXUIElement? {
        // First window with a non-empty title is the default for the
        // lifecycle adapter's `meetingWindow` handle field. Button
        // discovery in `build` searches every window separately so a
        // wrong pick here doesn't hide the mute / leave buttons.
        for w in windows {
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let title = titleRef as? String, !title.isEmpty else { continue }
            _ = title
            return w
        }
        return windows.first
    }

    /// Single observable surface for the AX walk's outcome. Emitted
    /// once per `build` call; tail with:
    ///   tail -200 ~/Library/Logs/MeetingPipe/events.jsonl \
    ///     | grep ax_handles_built
    /// `found_mute = false` for a native bundle with AX trusted is
    /// the signature symptom of "AX walk didn't find the button"
    /// (the gate then runs on HAL + RMS only and the user can speak
    /// while in-app muted).
    private static func emitDiagnostic(
        source: AppSource,
        axTrusted: Bool?,
        windowCount: Int,
        foundLeave: Bool,
        foundMute: Bool
    ) {
        var attrs: [String: Any] = [
            "bundle_id": source.bundleID,
            "kind": source.kind == .browser ? "browser" : "native",
            "window_count": windowCount,
            "found_leave": foundLeave,
            "found_mute": foundMute,
        ]
        if let axTrusted = axTrusted {
            attrs["ax_trusted"] = axTrusted
        }
        Log.event(category: "coordinator", action: "ax_handles_built", attributes: attrs)
    }

    /// Bounded depth-first walk for the first element that satisfies
    /// `predicate`. Mirrors the existing `MeetingWindowProbe` walk; the
    /// 12-depth ceiling is empirically generous for Teams' nested
    /// toolbar shells.
    private static func findButton(
        in element: AXUIElement,
        depth: Int,
        predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        if depth > maxDepth { return nil }
        var roleRef: CFTypeRef?
        let roleErr = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleErr == .success) ? (roleRef as? String) : nil
        if role == (kAXButtonRole as String) || role == (kAXCheckBoxRole as String) {
            if predicate(element) { return element }
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let hit = findButton(in: child, depth: depth + 1, predicate: predicate) {
                return hit
            }
        }
        return nil
    }

    private static func textBlob(_ el: AXUIElement) -> (String?, String?, String?) {
        let title = copyString(el, kAXTitleAttribute)
        let help = copyString(el, kAXHelpAttribute)
        let desc = copyString(el, kAXDescriptionAttribute)
        return (title, help, desc)
    }

    private static func copyString(_ el: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    static func matchesLeave(bundleID: String, element: AXUIElement) -> Bool {
        let (title, help, desc) = textBlob(element)
        return matchesLeave(bundleID: bundleID, title: title, help: help, description: desc)
    }

    /// Pure leave-button predicate. Reuses the same string set as the
    /// legacy `MeetingWindowProbe.isLeaveButton` so locale coverage
    /// matches what the daemon already shipped against.
    static func matchesLeave(bundleID: String, title: String?, help: String?, description: String?) -> Bool {
        let blob = [title, help, description]
            .compactMap { $0?.lowercased() }
            .joined(separator: " | ")
        if blob.isEmpty { return false }
        switch bundleID {
        case "us.zoom.xos":
            return blob.contains("leave") || blob.contains("end meeting")
        case "com.microsoft.teams2", "com.microsoft.teams":
            return blob.contains("leave") || blob.contains("hang up") || blob.contains("hangup")
        case "com.cisco.webexmeetingsapp", "com.cisco.spark":
            return blob.contains("leave meeting") || blob.contains("end meeting")
                || blob == "end" || blob.contains("leave")
        case "com.tinyspeck.slackmacgap":
            return blob.contains("leave huddle") || blob.contains("leave call") || blob.contains("end huddle")
        default:
            return false
        }
    }

    static func matchesMute(app: String, catalogue: MuteLabels, element: AXUIElement) -> Bool {
        let (title, help, desc) = textBlob(element)
        return matchesMute(app: app, catalogue: catalogue, title: title, help: help, description: desc)
    }

    /// Pure mute-button predicate. Matches against ANY locale in the
    /// `MuteLabels` catalogue for the given app, so the AX walk
    /// finds the button regardless of the user's system locale.
    /// Precise per-locale recognition happens later in
    /// `AXMuteButtonProbe.evaluate` against `Locale.current`.
    static func matchesMute(
        app: String,
        catalogue: MuteLabels,
        title: String?,
        help: String?,
        description: String?
    ) -> Bool {
        let blob = [title, help, description]
            .compactMap { $0?.lowercased() }
            .joined(separator: " | ")
        if blob.isEmpty { return false }
        guard let perLocale = catalogue.entries[app.lowercased()] else { return false }
        for entry in perLocale.values {
            for label in entry.actionMute + entry.actionUnmute + entry.statusMuted + entry.statusUnmuted {
                if blob.contains(label.lowercased()) { return true }
            }
        }
        return false
    }
}
