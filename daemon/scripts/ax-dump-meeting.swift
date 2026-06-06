#!/usr/bin/env swift
//
// Diagnostic for TECH-MIC6: dump the Accessibility tree of the running meeting
// clients (Teams, Zoom, Webex, Slack) so we can choose a durable, locale-
// independent mute signal instead of the localized button title the incident
// proved fragile. For each pressable control it prints role, subrole, title,
// help, description, AXValue, and AXIdentifier, plus a frame, so a stable state
// attribute (AXValue / pressed state) or a non-localized AXIdentifier can be
// picked per app.
//
// Run it WHILE IN A CALL in each app (let Teams shrink to the compact bar too,
// so the mini-window controls are captured):
//
//     swift daemon/scripts/ax-dump-meeting.swift
//
// Requires Accessibility permission for whatever runs it: System Settings ->
// Privacy & Security -> Accessibility -> enable Terminal (or your IDE), then
// re-run. A developer tool, not shipped in the app.
//
import AppKit
import ApplicationServices

struct Target {
    let app: String
    let bundleIDs: [String]
}

let targets = [
    Target(app: "teams", bundleIDs: ["com.microsoft.teams2", "com.microsoft.teams"]),
    Target(app: "zoom", bundleIDs: ["us.zoom.xos"]),
    Target(app: "webex", bundleIDs: ["com.cisco.webexmeetingsapp", "com.cisco.spark"]),
    Target(app: "slack", bundleIDs: ["com.tinyspeck.slackmacgap"]),
]

guard AXIsProcessTrusted() else {
    print("✗ This process is NOT Accessibility-trusted.")
    print("  Grant the app running this script (Terminal/iTerm/your IDE) in")
    print("  System Settings -> Privacy & Security -> Accessibility, then re-run.")
    exit(1)
}

func str(_ el: AXUIElement, _ attr: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
    if let s = value as? String, !s.isEmpty { return s }
    if let n = value as? NSNumber { return n.stringValue }
    if let b = value as? Bool { return b ? "true" : "false" }
    return nil
}

func children(_ el: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &value) == .success,
          let arr = value as? [AXUIElement] else { return [] }
    return arr
}

func frame(_ el: AXUIElement) -> String {
    var posVal: CFTypeRef?
    var sizeVal: CFTypeRef?
    var pos = CGPoint.zero
    var size = CGSize.zero
    if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posVal) == .success {
        AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
    }
    if AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeVal) == .success {
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
    }
    return "(\(Int(pos.x)),\(Int(pos.y)) \(Int(size.width))x\(Int(size.height)))"
}

// Roles we care about: any pressable/togglable control, plus images (icon-only
// buttons sometimes expose as AXImage) so a re-roled mic control still shows up.
let interestingRoles: Set<String> = [
    "AXButton", "AXCheckBox", "AXMenuButton", "AXRadioButton",
    "AXPopUpButton", "AXImage", "AXToggle", "AXDisclosureTriangle"
]
let keywordHints = ["mute", "unmute", "mic", "microphone", "leave", "hang", "call",
                    "звук", "мікрофон", "вийти", "залиш"]

func q(_ s: String) -> String { "\"\(s)\"" }

func describe(_ el: AXUIElement) -> String {
    var parts = ["role=\(str(el, kAXRoleAttribute as String) ?? "?")"]
    if let sub = str(el, kAXSubroleAttribute as String) { parts.append("subrole=\(sub)") }
    if let title = str(el, kAXTitleAttribute as String) { parts.append("title=\(q(title))") }
    if let help = str(el, kAXHelpAttribute as String) { parts.append("help=\(q(help))") }
    if let desc = str(el, kAXDescriptionAttribute as String) { parts.append("desc=\(q(desc))") }
    // The durable-signal candidates TECH-MIC6 wants to read instead of the title.
    if let value = str(el, kAXValueAttribute as String) { parts.append("value=\(q(value))") }
    if let ident = str(el, kAXIdentifierAttribute as String) { parts.append("id=\(q(ident))") }
    parts.append("frame=\(frame(el))")
    return parts.joined(separator: " ")
}

func matchesHint(_ el: AXUIElement) -> Bool {
    let blob = [
        str(el, kAXTitleAttribute as String),
        str(el, kAXHelpAttribute as String),
        str(el, kAXDescriptionAttribute as String),
    ].compactMap { $0 }.joined(separator: " ").lowercased()
    return keywordHints.contains { blob.contains($0) }
}

var matchedCount = 0
func walk(_ el: AXUIElement, depth: Int) {
    let role = str(el, kAXRoleAttribute as String) ?? "?"
    let hinted = matchesHint(el)
    if interestingRoles.contains(role) || hinted {
        let flag = hinted ? "  <<< mic/leave candidate" : ""
        print("\(String(repeating: "  ", count: depth))• \(describe(el))\(flag)")
        if hinted { matchedCount += 1 }
    }
    for child in children(el) { walk(child, depth: depth + 1) }
}

var anyRunning = false
for target in targets {
    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        target.bundleIDs.contains($0.bundleIdentifier ?? "")
    }) else { continue }
    anyRunning = true
    let pid = app.processIdentifier
    print("\n========== \(target.app) pid=\(pid) bundle=\(app.bundleIdentifier ?? "?") ==========")
    let axApp = AXUIElementCreateApplication(pid)
    let windows = children(axApp).filter { (str($0, kAXRoleAttribute as String) ?? "") == "AXWindow" }
    print("windows: \(windows.count)")
    for (i, win) in windows.enumerated() {
        let title = str(win, kAXTitleAttribute as String) ?? "(untitled)"
        print("───────── window[\(i)] \(q(title)) \(frame(win)) ─────────")
        walk(win, depth: 0)
    }
}

if !anyRunning {
    print("✗ None of the target meeting apps are running \(targets.map { $0.app }).")
    exit(1)
}

print("\nDone. mic/leave candidates flagged: \(matchedCount)")
print("Paste the flagged lines back so the mute matcher can move to the durable")
print("attribute (value / id) instead of the localized title (TECH-MIC6).")
