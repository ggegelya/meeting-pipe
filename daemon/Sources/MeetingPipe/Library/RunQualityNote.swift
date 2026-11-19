import Foundation

/// OBS8: the quiet notes the detail header adds under the provenance line when a run's own
/// checks say its summary deserves a second look. Pure, over `<stem>.run.json`'s counts.
///
/// Two signals the pipeline already measures and nothing showed per meeting: how many of the
/// citations the engine proposed failed verification (FEAT10 drops a quote that is not in the
/// transcript near its time), and how many lines the speaker cleanup relabelled. Across 110
/// meetings a quarter of citations were dropped and 18 percent of lines relabelled, so these
/// fire only well above that: more than half the citations, more than a quarter of the lines.
enum RunQualityNote {
    static func notes(
        evidenceKept: Int?, evidenceDropped: Int?,
        cleanupChanged: Int?, cleanupSegments: Int?
    ) -> [String] {
        var out: [String] = []
        if let kept = evidenceKept, let dropped = evidenceDropped, kept >= 0, dropped >= 0,
           dropped * 2 > kept + dropped {
            out.append("Most of the quotes the engine cited could not be found in the transcript, so fewer points have a source to check.")
        }
        if let changed = cleanupChanged, let total = cleanupSegments, total > 0, changed >= 0,
           changed * 4 > total {
            out.append("The speaker clean-up changed who said over a quarter of the lines. Worth a look in the Transcript tab.")
        }
        return out
    }
}
