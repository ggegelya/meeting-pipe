import ApplicationServices
import Foundation

/// Best-effort meeting-title extraction.
///
/// Walks a meeting app's AX window titles and pulls a human-readable
/// meeting name out of the window / tab title chrome. Each app has its
/// own conventions, so the extractors are per-bundle. Failures (AX
/// denied, no match, junk like a raw room code) return nil and the
/// pipeline falls back to the LLM-derived title.
///
/// Lifted out of `Detector` (TECH-C13 step 5) so the lifecycle context
/// bridge can resolve titles after Detector is gone.
enum MeetingTitleResolver {

    /// Walk the AX windows of `pid` and extract the meeting title.
    /// Returns nil when AX is denied, the read fails, or no window
    /// title matches the per-bundle pattern.
    static func resolve(bundleID: String, kind: AppSourceKind, pid: pid_t) -> String? {
        guard AXIsProcessTrusted(),
              let titles = MeetingSourceScanner.collectAXWindowTitles(pid: pid) else {
            return nil
        }
        return extractMeetingTitle(bundleID: bundleID, kind: kind, titles: titles)
    }

    /// Pure function: given a bundle ID and a list of titles, return the
    /// first useful meeting name we can extract. Trivially unit-testable
    /// without AX.
    static func extractMeetingTitle(bundleID: String, kind: AppSourceKind, titles: [String]) -> String? {
        switch (bundleID, kind) {
        case ("us.zoom.xos", _):
            return titles.lazy.compactMap(extractZoomNativeTitle).first
        case ("com.microsoft.teams2", .native), ("com.microsoft.teams", .native):
            return titles.lazy.compactMap(extractTeamsNativeTitle).first
        case ("com.cisco.webexmeetingsapp", _):
            return titles.lazy.compactMap(extractWebexNativeTitle).first
        case ("com.tinyspeck.slackmacgap", _):
            return titles.lazy.compactMap(extractSlackTitle).first
        default:
            if kind == .browser {
                return titles.lazy.compactMap(extractBrowserMeetingTitle).first
            }
            return nil
        }
    }

    private static func extractZoomNativeTitle(_ t: String) -> String? {
        // "<Topic> | Zoom Meeting" / "<Topic> - Zoom Meeting" / bare "Zoom Meeting"
        if let topic = firstCaptureGroup(t, pattern: #"^\s*(.+?)\s*[|\-]\s*Zoom Meeting\s*$"#),
           !topic.isEmpty, topic.lowercased() != "zoom" {
            return topic
        }
        return nil
    }

    private static func extractTeamsNativeTitle(_ t: String) -> String? {
        // Modern Teams: "Meeting in <Channel> | Microsoft Teams"
        //               "Meeting with <Person> | Microsoft Teams"
        if let topic = firstCaptureGroup(t, pattern: #"^\s*Meeting (?:in|with)\s+(.+?)\s*\|\s*Microsoft Teams\s*$"#) {
            return topic
        }
        return nil
    }

    private static func extractWebexNativeTitle(_ t: String) -> String? {
        if let topic = firstCaptureGroup(t, pattern: #"^\s*Webex Meeting\s*\|\s*(.+?)\s*$"#) {
            return topic
        }
        if let topic = firstCaptureGroup(t, pattern: #"^\s*(.+?)\s*-\s*Webex\s*$"#) {
            return topic
        }
        return nil
    }

    private static func extractSlackTitle(_ t: String) -> String? {
        // "<Channel> Huddle" → "<Channel>". Slack also uses titles like
        // "Slack | <Channel> | Huddle" depending on version; cover both.
        if let topic = firstCaptureGroup(t, pattern: #"^\s*(.+?)\s+Huddle\s*$"#) {
            return topic
        }
        if let topic = firstCaptureGroup(t, pattern: #"^\s*Slack\s*\|\s*(.+?)\s*\|\s*Huddle\s*$"#) {
            return topic
        }
        return nil
    }

    private static func extractBrowserMeetingTitle(_ t: String) -> String? {
        let lower = t.lowercased()

        if lower.contains("google meet") || lower.hasPrefix("meet ") || lower.contains(" meet -") {
            // "<Calendar event or RoomCode> - Google Meet"
            if let topic = firstCaptureGroup(t, pattern: #"^\s*(.+?)\s*-\s*Google Meet\s*$"#) {
                return isJustMeetRoomCode(topic) ? nil : topic
            }
            // Older / alternate format: "Meet - <name>"
            if let topic = firstCaptureGroup(t, pattern: #"^\s*Meet\s*-\s*(.+?)\s*$"#) {
                return isJustMeetRoomCode(topic) ? nil : topic
            }
        }

        if lower.contains("microsoft teams") {
            if let topic = firstCaptureGroup(t, pattern: #"^\s*(.+?)\s*\|\s*Microsoft Teams\s*$"#),
               topic.lowercased() != "microsoft teams" {
                return topic
            }
        }

        if lower.contains("webex") {
            if let topic = firstCaptureGroup(t, pattern: #"^\s*(.+?)\s*-\s*Webex\s*$"#) {
                return topic
            }
        }

        // Zoom web client. Skip if title is just the generic chrome.
        if lower.contains("zoom") {
            if let topic = firstCaptureGroup(t, pattern: #"^\s*(.+?)\s*[|\-]\s*Zoom\s*$"#),
               topic.lowercased() != "zoom" {
                return topic
            }
        }

        return nil
    }

    /// Google Meet ad-hoc room codes look like `abc-defg-hij`. They make
    /// terrible Notion titles, so reject them and let the LLM-derived
    /// title win as a fallback.
    private static func isJustMeetRoomCode(_ s: String) -> Bool {
        return s.range(of: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil
    }

    private static func firstCaptureGroup(_ s: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let match = regex.firstMatch(in: s, options: [], range: range), match.numberOfRanges > 1 else { return nil }
        let g = match.range(at: 1)
        guard let r = Range(g, in: s) else { return nil }
        let captured = String(s[r]).trimmingCharacters(in: .whitespaces)
        return captured.isEmpty ? nil : captured
    }
}
