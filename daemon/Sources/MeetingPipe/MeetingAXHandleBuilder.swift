import AppKit
import ApplicationServices
import Foundation
import MeetingPipeCore

/// One-time AX walk per meeting that resolves the Leave + Mute buttons for
/// the matched app, packaged into the handles `MeetingLifecycleCoordinator`
/// and `MicGate` expect. The tree is walked once at start; later changes
/// flow through observers + health polls.
///
/// Browser meetings get an empty handle (WKWebView exposes no AX call
/// controls), so lifecycle falls back to ShareableContent + window-title and
/// MicGate to HAL VAD + RMS.
enum MeetingAXHandleBuilder {

    struct Handles {
        let lifecycle: LifecycleAdapterHandle
        let micGate: MicGateAdapterHandle
        let context: MeetingLifecycleContext
    }

    /// Bundle ID to the `MuteLabels` short app name (for per-locale labels).
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

        // Browsers expose no AX call controls (HAL + RMS only). Resolve a
        // meeting window for PWAs only: a tabless PWA window's title change
        // is a real join/leave, whereas a regular browser's shared-window
        // title change is usually a tab switch and would false-end a live
        // meeting in a background tab.
        if kind == .browser {
            var meetingWindow: AXUIElement?
            let browserAXTrusted = AXIsProcessTrusted()
            if browserAXTrusted,
               BrowserMeetingLifecycleAdapter.isPWABundleID(source.bundleID) {
                let axApp = AXUIElementCreateApplication(pid)
                meetingWindow = pickMeetingWindow(windows: listWindows(axApp: axApp))
            }
            emitDiagnostic(source: source, axTrusted: browserAXTrusted,
                           windowCount: meetingWindow == nil ? 0 : 1,
                           foundLeave: false, foundMute: false)
            return Handles(
                lifecycle: LifecycleAdapterHandle(meetingWindow: meetingWindow),
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

        // Leave: first match across every window, decoupled from the picked meetingWindow (Teams'
        // window order isn't always [meeting, chat], so the title-first picker can grab the chat
        // window while the buttons live elsewhere).
        var leave: AXUIElement?
        for w in allWindows {
            leave = findButton(in: w, depth: 0) { el in
                matchesLeave(bundleID: source.bundleID, element: el)
            }
            if leave != nil { break }
        }

        // Mute: the SCOPED walk, not a first-match-across-windows scan (MIC10 part 1). The primary
        // `AXMuteButtonProbe` caches this element and subscribes to it for the whole meeting, so
        // handing it the frozen button from the backgrounded full window latches `muted` for the
        // rest of the call and no later poll can undo it. Window order is not guaranteed, so the
        // old scan was choosing the live control by luck.
        let mute = MeetingAXHandleBuilder.findMeetingWindowMuteButtons(
            in: axApp, bundleID: source.bundleID, catalogue: catalogue
        ).first

        emitDiagnostic(
            source: source,
            axTrusted: true,
            windowCount: allWindows.count,
            foundLeave: leave != nil,
            foundMute: mute != nil,
            foundCallPanel: allWindows.contains(where: isCallPanel)
        )

        // Re-arm resolver for the primary probe (TECH-MIC6): the same
        // leave-scoped walk the window watcher uses, so a re-render or
        // compact-view swap that staled the cached element recovers a live one.
        let bundleID = source.bundleID
        let resolveMute: () -> AXUIElement? = {
            MeetingAXHandleBuilder.findMeetingWindowMuteButtons(
                in: axApp, bundleID: bundleID, catalogue: catalogue
            ).first
        }
        // TECH-END2: fresh leave-button walk so AXLeaveButtonSignal can re-resolve a
        // transiently-staled element (Teams call-UI re-render) before declaring the
        // meeting ended, instead of emitting a false `.ended` (the screen-share repro).
        let resolveLeave: () -> AXUIElement? = {
            MeetingAXHandleBuilder.findAllLeaveButtons(in: axApp, bundleID: bundleID).first
        }

        return Handles(
            lifecycle: LifecycleAdapterHandle(
                leaveButton: leave,
                meetingWindow: meetingWindow,
                resolveLeaveButton: resolveLeave
            ),
            micGate: MicGateAdapterHandle(muteButton: mute, resolveMuteButton: resolveMute),
            context: context
        )
    }

    // MARK: - Private

    /// Depth ceiling for the per-window button walk. Teams 2 is Electron
    /// and nests the Mute button ~20 levels deep (verified via Accessibility
    /// Inspector, 2026-05-20); 32 leaves margin for future Chromium nesting
    /// at negligible walk cost (well under 100 nodes total).
    private static let maxDepth = 32

    /// Total AX nodes a single walk may visit. `maxDepth` bounds how *deep* the
    /// DFS goes; this bounds how *wide* it goes, so a pathological tree (an AX
    /// reference cycle, or a meeting window with a very large node count) can't
    /// turn one walk into thousands of synchronous AX round-trips on the caller's
    /// thread. Sized far above a real meeting window (happy path is well under
    /// 100 nodes) so it never causes a false miss; it is a runaway backstop, not
    /// a tuning knob.
    private static let maxNodes = 4000

    /// Return all AX windows of `axApp`. Internal so
    /// `MeetingAXWindowWatcher` can re-walk on a window-created
    /// notification without duplicating the `kAXWindowsAttribute`
    /// dance.
    static func allWindows(of axApp: AXUIElement) -> [AXUIElement] {
        listWindows(axApp: axApp)
    }

    /// Walk every window of an axApp and return every mute button
    /// the existing `matchesMute` predicate accepts. Used by
    /// `MeetingSourceScanner` for the "a mute button exists" detection
    /// signal. The mute-state poller uses the leave-scoped
    /// `findMeetingWindowMuteButtons` instead, so a stale hub-window toggle
    /// can't be read as the live mute state.
    static func findAllMuteButtons(
        in axApp: AXUIElement,
        bundleID: String,
        catalogue: MuteLabels
    ) -> [AXUIElement] {
        guard let app = appNameByBundle[bundleID] else { return [] }
        var result: [AXUIElement] = []
        for window in listWindows(axApp: axApp) {
            if let button = findButton(in: window, depth: 0, predicate: { el in
                matchesMute(app: app, catalogue: catalogue, element: el)
            }) {
                result.append(button)
            }
        }
        return result
    }

    /// Mute button(s) scoped to the live in-call control (MIC10 part 1, re-anchored 2026-07-14
    /// off a live AX dump of a real Teams call).
    ///
    /// What the dump showed, and why the old Leave anchor could never work. During a call with
    /// the Teams window backgrounded, THREE windows exist, and TWO of them expose a mute button
    /// AND a `Leave` button, so the Leave anchor keeps both:
    ///
    ///   win[0] "Meeting compact view | ..."  subrole=AXSystemDialog    desc="Unmute mic" -> "Mute mic"
    ///   win[1] "Calendar | ..."              subrole=AXStandardWindow  (no mute button)
    ///   win[2] "Meeting with ... | ..."      subrole=AXStandardWindow  desc="Unmute mic" (frozen)
    ///
    /// Toggling the real mic flips only win[0]. win[2], the full meeting window the call popped
    /// out of, FREEZES its mute description at whatever it last rendered and reads `muted`
    /// (`desc="Unmute mic"` means "click to unmute", i.e. currently muted) for the rest of the
    /// call. So the stale control is not the hub / pre-join window that MIC9 and MIC10 both
    /// blamed: it is the backgrounded full window of the very same call, which is why every
    /// Leave-based scoping attempt kept it (it carries a Leave button too) and why the
    /// MUTED-biased fusion then zeroed a live mic for a whole meeting (the 2026-06-08 loss).
    ///
    /// The anchor: the floating compact call panel is the only `AXSystemDialog` window; the rest
    /// are `AXStandardWindow`. That is a locale-independent AX constant, not a localized string,
    /// so it satisfies the MIC6 bar (Teams exposes no AXValue and no AXIdentifier anywhere in its
    /// tree, so a subrole is the durable structural signal actually on offer).
    static func findMeetingWindowMuteButtons(
        in axApp: AXUIElement,
        bundleID: String,
        catalogue: MuteLabels
    ) -> [AXUIElement] {
        guard let app = appNameByBundle[bundleID] else { return [] }
        var entries: [(value: AXUIElement, isCallPanel: Bool, hasLeave: Bool)] = []
        for window in listWindows(axApp: axApp) {
            guard let mute = findButton(in: window, depth: 0, predicate: { el in
                matchesMute(app: app, catalogue: catalogue, element: el)
            }) else { continue }
            let hasLeave = findButton(in: window, depth: 0, predicate: { el in
                matchesLeave(bundleID: bundleID, element: el)
            }) != nil
            entries.append((mute, isCallPanel(window), hasLeave))
        }
        return scopeToLiveControl(entries)
    }

    /// True when a window is the floating call panel (Teams' "Meeting compact view"), which the
    /// live AX dump proves is the only mute control that tracks the real mic. `AXSystemDialog` is
    /// a standard AX subrole constant, so this survives a locale change and a re-labelled button.
    private static func isCallPanel(_ window: AXUIElement) -> Bool {
        copyString(window, kAXSubroleAttribute) == (kAXSystemDialogSubrole as String)
    }

    /// Pick the live mute control out of the candidate windows. Pure, so the scoping rule is
    /// unit-tested without a live AX tree. Precedence, each layer evidenced rather than guessed:
    ///
    /// 1. The floating call panel wins outright when it is present. The dump proves it is the live
    ///    control and that the full meeting window freezes behind it, so reading both (which is
    ///    what every earlier version did) is what let a frozen button out-vote a live one.
    /// 2. Otherwise keep the windows that also expose a Leave control (the pre-MIC10 rule). With no
    ///    panel around, a call rendered in the main window is the live one and it carries Leave.
    /// 3. Otherwise keep everything, so a missed Leave walk degrades to the old all-windows read
    ///    rather than returning an empty set and silencing the poller. `MeetingAXWindowWatcher`'s
    ///    cross-window disagreement rule is the backstop for whatever still slips through here.
    static func scopeToLiveControl<T>(
        _ entries: [(value: T, isCallPanel: Bool, hasLeave: Bool)]
    ) -> [T] {
        let panel = entries.filter { $0.isCallPanel }.map { $0.value }
        if !panel.isEmpty { return panel }
        return preferWindowsWithLeave(entries.map { (value: $0.value, hasLeave: $0.hasLeave) })
    }

    /// Keep only entries whose window also exposes a Leave control; if none
    /// does, keep all. Pure, so the in-call-window scoping rule is unit-tested
    /// without a live AX tree. The all-or-nothing fallback is deliberate: a
    /// read that finds no Leave button anywhere (a compact view the leave
    /// matcher missed, an AX hiccup) must not return an empty set and silence
    /// the poller; it degrades to the pre-scoping all-windows behaviour.
    static func preferWindowsWithLeave<T>(_ entries: [(value: T, hasLeave: Bool)]) -> [T] {
        let scoped = entries.filter { $0.hasLeave }.map { $0.value }
        return scoped.isEmpty ? entries.map { $0.value } : scoped
    }

    /// Walk every window of an axApp and return every leave button the
    /// per-bundle leave predicate accepts. Mirrors `findAllMuteButtons`
    /// for the scorer's Leave-button-found signal (TECH-C15). One
    /// button per window at most; the search short-circuits at the
    /// first hit per window so cost stays bounded.
    static func findAllLeaveButtons(
        in axApp: AXUIElement,
        bundleID: String
    ) -> [AXUIElement] {
        var result: [AXUIElement] = []
        for window in listWindows(axApp: axApp) {
            if let button = findButton(in: window, depth: 0, predicate: { el in
                matchesLeave(bundleID: bundleID, element: el)
            }) {
                result.append(button)
            }
        }
        return result
    }

    /// First Calling-/Meeting-controls toolbar across all windows (TECH-C15),
    /// matched by per-bundle title needles. Bonus weight on top of the
    /// leave + mute buttons, so no-match is safe.
    static func findCallingControlsToolbar(
        in axApp: AXUIElement,
        bundleID: String
    ) -> AXUIElement? {
        let needles = callingControlsToolbarNeedles(bundleID: bundleID)
        guard !needles.isEmpty else { return nil }
        for window in listWindows(axApp: axApp) {
            if let toolbar = findToolbar(in: window, depth: 0, needles: needles) {
                return toolbar
            }
        }
        return nil
    }

    /// Per-bundle toolbar-title needles (case-insensitive substring).
    /// Browsers share the Meet pattern since the controls live in the page.
    static func callingControlsToolbarNeedles(bundleID: String) -> [String] {
        switch bundleID {
        case "com.microsoft.teams2", "com.microsoft.teams":
            return ["calling controls"]
        case "us.zoom.xos":
            return ["meeting controls"]
        case "com.cisco.webexmeetingsapp", "com.cisco.spark":
            return ["meeting controls", "call controls"]
        case "com.tinyspeck.slackmacgap":
            return ["huddle controls", "call controls"]
        default:
            // Browsers and unknown natives: Meet-style labelling. Cheap
            // superset that doesn't fire on non-meeting windows.
            return ["meeting controls", "call controls"]
        }
    }

    private static func listWindows(axApp: AXUIElement) -> [AXUIElement] {
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return []
        }
        return windows
    }

    private static func pickMeetingWindow(windows: [AXUIElement]) -> AXUIElement? {
        // First titled window, for the `meetingWindow` field only; `build`
        // searches every window for buttons, so a wrong pick is harmless.
        for w in windows {
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let title = titleRef as? String, !title.isEmpty else { continue }
            _ = title
            return w
        }
        return windows.first
    }

    /// One `ax_handles_built` event per `build`. `found_mute=false` on a
    /// native bundle with AX trusted is the signature "AX walk missed the
    /// button" symptom (the gate then runs HAL + RMS only). `found_call_panel`
    /// says whether the floating compact call panel (the live mute control per
    /// MIC10 part 1) was on screen, so the log can show the re-anchor working:
    /// a panel present with `buttons_found: 1` in the poll is the fixed shape.
    private static func emitDiagnostic(
        source: AppSource,
        axTrusted: Bool?,
        windowCount: Int,
        foundLeave: Bool,
        foundMute: Bool,
        foundCallPanel: Bool = false
    ) {
        var attrs: [String: Any] = [
            "bundle_id": source.bundleID,
            "kind": source.kind == .browser ? "browser" : "native",
            "window_count": windowCount,
            "found_leave": foundLeave,
            "found_mute": foundMute,
            "found_call_panel": foundCallPanel,
        ]
        if let axTrusted = axTrusted {
            attrs["ax_trusted"] = axTrusted
        }
        Log.event(category: "coordinator", action: "ax_handles_built", attributes: attrs)
    }

    /// Bounded DFS for the first button/checkbox satisfying `predicate`. Entry
    /// point: allocates a fresh per-walk node budget, then delegates.
    private static func findButton(
        in element: AXUIElement,
        depth: Int,
        predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        var budget = maxNodes
        return findButton(in: element, depth: depth, budget: &budget, predicate: predicate)
    }

    private static func findButton(
        in element: AXUIElement,
        depth: Int,
        budget: inout Int,
        predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        if depth > maxDepth || budget <= 0 { return nil }
        budget -= 1
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
            if let hit = findButton(in: child, depth: depth + 1, budget: &budget, predicate: predicate) {
                return hit
            }
        }
        return nil
    }

    /// Bounded DFS for the first toolbar/group whose text contains any needle.
    /// Entry point: allocates a fresh per-walk node budget, then delegates.
    private static func findToolbar(
        in element: AXUIElement,
        depth: Int,
        needles: [String]
    ) -> AXUIElement? {
        var budget = maxNodes
        return findToolbar(in: element, depth: depth, budget: &budget, needles: needles)
    }

    private static func findToolbar(
        in element: AXUIElement,
        depth: Int,
        budget: inout Int,
        needles: [String]
    ) -> AXUIElement? {
        if depth > maxDepth || budget <= 0 { return nil }
        budget -= 1
        var roleRef: CFTypeRef?
        let roleErr = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleErr == .success) ? (roleRef as? String) : nil
        if role == (kAXToolbarRole as String) || role == (kAXGroupRole as String) {
            let (title, help, desc) = textBlob(element)
            let blob = [title, help, desc]
                .compactMap { $0?.lowercased() }
                .joined(separator: " | ")
            if !blob.isEmpty && needles.contains(where: { blob.contains($0) }) {
                return element
            }
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let hit = findToolbar(in: child, depth: depth + 1, budget: &budget, needles: needles) {
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
            // Match the call control by phrase, not a bare "leave"
            // substring. Teams chrome buttons such as "Leave feedback",
            // "Leave team", and "Leave organization" otherwise made an
            // idle Settings window read as a live call.
            return isTeamsCallLeaveLabel(title)
                || isTeamsCallLeaveLabel(help)
                || isTeamsCallLeaveLabel(description)
        case "com.cisco.webexmeetingsapp", "com.cisco.spark":
            return blob.contains("leave meeting") || blob.contains("end meeting")
                || blob == "end" || blob.contains("leave")
        case "com.tinyspeck.slackmacgap":
            return blob.contains("leave huddle") || blob.contains("leave call") || blob.contains("end huddle")
        default:
            return false
        }
    }

    /// True when an AX label names the Teams Leave/Hang-up control. Exact
    /// match (after dropping a shortcut hint), not substring: "leave"
    /// substring also matched "Leave feedback/team/organization" and made
    /// the Settings window read as a live call (false prompt).
    static func isTeamsCallLeaveLabel(_ text: String?) -> Bool {
        guard var t = text?.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            return false
        }
        if t.contains("hang up") || t.contains("hangup") { return true }
        // Drop a trailing keyboard-shortcut hint, e.g. "leave (⌘⇧h)".
        if let paren = t.firstIndex(of: "(") {
            t = String(t[..<paren]).trimmingCharacters(in: .whitespaces)
        }
        switch t {
        case "leave", "leave call", "leave meeting",
             "leave the call", "leave the meeting":
            return true
        default:
            return false
        }
    }

    static func matchesMute(app: String, catalogue: MuteLabels, element: AXUIElement) -> Bool {
        let (title, help, desc) = textBlob(element)
        return matchesMute(app: app, catalogue: catalogue, title: title, help: help, description: desc)
    }

    /// Pure mute-button predicate, matching ANY locale in the catalogue so
    /// the walk finds the button regardless of system locale; precise
    /// per-locale recognition is `AXMuteButtonProbe.evaluate`'s job later.
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
        // Word-boundary match (see MuteLabels.containsAsWord): a raw substring
        // picked up Teams 2's "Unmuted (...)" status button and injected
        // spurious .muted events.
        for entry in perLocale.values {
            for label in entry.actionMute + entry.actionUnmute + entry.statusMuted + entry.statusUnmuted {
                if MuteLabels.containsAsWord(blob: blob, label: label) { return true }
            }
        }
        return false
    }
}
