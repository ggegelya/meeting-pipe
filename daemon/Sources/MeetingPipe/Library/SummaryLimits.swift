import Foundation

/// PIPE54: the three limits the pipeline's `schemas.MeetingSummary` enforces on `<stem>.summary.json`
/// (ADR 0014: Python is the source of truth, Swift mirrors it). `mp publish` re-validates the file
/// before any sink runs, so a Swift writer that exceeds one fails every later publish of that
/// meeting. Pinned against the pipeline by `Fixtures/summary-limits-golden.json`, which
/// `scripts/gen_contract_fixtures.py` generates from `MeetingSummary.model_json_schema()`.
extension MeetingSummary {
    /// `title: str = Field(..., max_length=120)`, counted in Unicode scalars as Python counts.
    static let titleMaxLength = 120
    /// `summary: list[str] = Field(..., max_length=10)`.
    static let summaryMaxItems = 10
    /// PIPE43 (F176): `title` has `min_length=1` (and a blank one is refused), `summary` has
    /// `min_length=1` after blank bullets are dropped. The editor refuses a save below either.
    static let titleMinLength = 1
    static let summaryMinItems = 1
    /// `ActionItem.confidence: Literal["low", "medium", "high"]`.
    static let confidenceValues = ["low", "medium", "high"]

    /// Python's `len()` of a string: Unicode scalars, not grapheme clusters, so an emoji with a
    /// skin tone counts as Python counts it.
    static func schemaLength(_ text: String) -> Int { text.unicodeScalars.count }

    /// The first `titleMaxLength` scalars of `text`.
    static func clampTitle(_ text: String) -> String {
        guard schemaLength(text) > titleMaxLength else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix(titleMaxLength)))
    }

    /// The line under a title field once it reaches the limit, nil below it. The fields stop at the
    /// limit, so this is what tells the owner why typing stopped.
    static func titleLimitNote(_ text: String) -> String? {
        schemaLength(text) >= titleMaxLength ? "Titles stop at \(titleMaxLength) characters." : nil
    }

    /// A confidence outside the enum becomes "medium", exactly as `digest._clamp_confidence` does
    /// (case-sensitive, so "High" is outside it too), and as an empty one already did here.
    static func clampConfidence(_ value: String) -> String {
        confidenceValues.contains(value) ? value : "medium"
    }

    /// The write backstop: title to the limit, the summary to its first `summaryMaxItems` bullets
    /// (and their anchors with them), every confidence onto the enum. The editor refuses before
    /// this is ever needed; it is what keeps the machine writers (the Apple summarizer's parse, a
    /// file loaded over the limit) from writing a file `mp publish` rejects.
    func clampedToSchema() -> MeetingSummary {
        var out = self
        out.title = Self.clampTitle(title)
        if summary.count > Self.summaryMaxItems {
            out.summary = Array(summary.prefix(Self.summaryMaxItems))
            if let anchors = evidence["summary"] {
                out.evidence["summary"] = Array(anchors.prefix(Self.summaryMaxItems))
            }
        }
        out.actions = actions.map { a in
            var a = a
            a.confidence = Self.clampConfidence(a.confidence)
            return a
        }
        return out
    }
}
