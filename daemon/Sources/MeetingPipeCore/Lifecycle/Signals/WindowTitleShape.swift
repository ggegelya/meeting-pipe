import Foundation

/// SEC38: the shape class of a window title, which is what the event log carries in place of the
/// title itself. A title is meeting content (a topic, a person's name, a customer), and the event log
/// is handed to analysis sessions as a diagnostics pack, so a row records which kind of title it saw,
/// never the text. No hash either: an unsalted hash of a guessable title is recoverable by hashing
/// guesses.
///
/// The classes answer the question the titles used to answer (END14: "did the call window stop
/// carrying a brand token?"). One vocabulary with DET17's `browser_identity` row: its `meet_bare`,
/// `meet_landing` and `meet_other` are refinements of `brand_token` for the Meet brand, and the
/// identity-mode apps' own classes (`MeetingTitlePatterns.windowShape`) refine `matches`.
public enum WindowTitleShape {
    /// The probe returned no title at all.
    public static let none = "nil"
    /// A title that is empty or only whitespace.
    public static let empty = "empty"
    /// The title satisfies one of the caller's matchers (the adapter's in-meeting patterns).
    public static let matches = "matches"
    /// No matcher fires, but the title names a meeting product.
    public static let brandToken = "brand_token"
    /// Anything else.
    public static let other = "other"

    /// The product words a meeting window or tab can carry, matched on word boundaries,
    /// case-insensitively.
    static let brandTokens = ["microsoft teams", "teams", "zoom", "webex", "google meet", "meet", "slack", "huddle"]

    /// Pure. `patterns` are the caller's own title matchers; an empty list never yields `matches`.
    public static func classify(_ title: String?, patterns: [(String?) -> Bool] = []) -> String {
        guard let title else { return none }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return empty }
        if patterns.contains(where: { $0(title) }) { return matches }
        let lowered = trimmed.lowercased()
        for token in brandTokens {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: token) + "(?![\\p{L}\\p{N}])"
            if lowered.range(of: pattern, options: .regularExpression) != nil { return brandToken }
        }
        return other
    }
}
