#!/usr/bin/env swift

// Dump AX window titles for a running app, formatted as a fixture
// entry ready to paste into
// `daemon/Tests/MeetingPipeTests/Fixtures/window_titles.json`.
//
// Usage:
//   swift scripts/dump_window_titles.swift <bundle_id> <state_label> <recognize|reject>
//
// Example:
//   swift scripts/dump_window_titles.swift us.zoom.xos in_call_with_topic recognize
//
// Requires Accessibility permission for the calling Terminal/iTerm.
// On a fresh shell, run once: `tccutil reset Accessibility` if titles
// come back empty, then re-grant via System Settings.

import AppKit
import ApplicationServices
import Foundation

func usageAndExit() -> Never {
    FileHandle.standardError.write(Data((
        "usage: dump_window_titles.swift <bundle_id> <state_label> <recognize|reject>\n"
    ).utf8))
    exit(2)
}

let args = CommandLine.arguments
guard args.count == 4 else { usageAndExit() }
let bundleID = args[1]
let state = args[2]
let expected = args[3]
guard expected == "recognize" || expected == "reject" else { usageAndExit() }

guard let app = NSWorkspace.shared.runningApplications.first(where: {
    $0.bundleIdentifier == bundleID
}) else {
    FileHandle.standardError.write(Data("no running app with bundleID \(bundleID)\n".utf8))
    exit(1)
}

if !AXIsProcessTrusted() {
    FileHandle.standardError.write(Data((
        "Accessibility permission not granted to this process. "
            + "Open System Settings -> Privacy & Security -> Accessibility "
            + "and add Terminal (or iTerm).\n"
    ).utf8))
    exit(1)
}

let axApp = AXUIElementCreateApplication(app.processIdentifier)
var windowsRef: CFTypeRef?
guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
      let windows = windowsRef as? [AXUIElement] else {
    FileHandle.standardError.write(Data("AX window read failed\n".utf8))
    exit(1)
}

var titles: [String] = []
for win in windows {
    var titleRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef) == .success,
       let title = titleRef as? String, !title.isEmpty {
        titles.append(title)
    }
}

let titleArray = titles.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    .joined(separator: ", ")

print("""
{
  "bundle_id": "\(bundleID)",
  "state": "\(state)",
  "expected": "\(expected)",
  "seeded": false,
  "titles": [\(titleArray)]
}
""")
