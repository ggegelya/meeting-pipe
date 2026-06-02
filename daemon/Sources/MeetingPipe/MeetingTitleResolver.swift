import ApplicationServices
import Foundation

/// Best-effort per-bundle extraction of a human-readable meeting name from AX window titles (TECH-C13 step 5). Failures (AX denied, no match, bare room code) return nil so the pipeline falls back to the LLM-derived title.
enum MeetingTitleResolver {

    /// Walk AX windows of `pid` and extract the meeting title. Returns nil when AX is denied, read fails, or no window matches.
    static func resolve(bundleID: String, kind: AppSourceKind, pid: pid_t) -> String? {
        guard AXIsProcessTrusted(),
              let titles = MeetingSourceScanner.collectAXWindowTitles(pid: pid) else {
            return nil
        }
        return extractMeetingTitle(bundleID: bundleID, kind: kind, titles: titles)
    }

    /// Pure: extract the first useful meeting name from `titles`. Unit-testable without AX.
    /// The result is scrubbed of control characters at this boundary (TECH-SEC7) so a
    /// crafted AX window title cannot inject YAML frontmatter keys or break the meta
    /// sidecar once the title flows into the pipeline.
    static func extractMeetingTitle(bundleID: String, kind: AppSourceKind, titles: [String]) -> String? {
        guard let raw = rawMeetingTitle(bundleID: bundleID, kind: kind, titles: titles) else {
            return nil
        }
        let clean = sanitizeTitle(raw)
        return clean.isEmpty ? nil : clean
    }

    private static func rawMeetingTitle(bundleID: String, kind: AppSourceKind, titles: [String]) -> String? {
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

    /// Scalars to neutralize in a title: line breaks (incl. U+2028 LINE SEPARATOR /
    /// U+2029 PARAGRAPH SEPARATOR, which are NOT in CharacterSet.controlCharacters)
    /// plus C0/C1 control chars and DEL. Deliberately excludes Unicode format
    /// characters (Cf, e.g. U+200D ZERO WIDTH JOINER) so emoji sequences survive.
    private static let titleUnsafeScalars: CharacterSet = {
        var set = CharacterSet.newlines
        set.insert(charactersIn: Unicode.Scalar(0x00)!...Unicode.Scalar(0x1F)!)  // C0 (incl tab)
        set.insert(Unicode.Scalar(0x7F)!)                                         // DEL
        set.insert(charactersIn: Unicode.Scalar(0x80)!...Unicode.Scalar(0x9F)!)   // C1
        return set
    }()

    /// Replace line breaks and control characters with spaces, then trim, so an
    /// extracted title is always single-line and safe for YAML frontmatter and the
    /// meta sidecar (TECH-SEC7). Regular spacing and formatting characters (e.g. the
    /// ZWJ in emoji sequences) are preserved.
    static func sanitizeTitle(_ s: String) -> String {
        let cleaned = String(s.unicodeScalars.map {
            titleUnsafeScalars.contains($0) ? Character(" ") : Character($0)
        })
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
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
        // Covers both "<Channel> Huddle" and "Slack | <Channel> | Huddle" (version-dependent).
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

        // Zoom web client; skip generic chrome titles.
        if lower.contains("zoom") {
            if let topic = firstCaptureGroup(t, pattern: #"^\s*(.+?)\s*[|\-]\s*Zoom\s*$"#),
               topic.lowercased() != "zoom" {
                return topic
            }
        }

        return nil
    }

    /// `abc-defg-hij` room codes make terrible Notion titles; reject and let the LLM-derived title win.
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
