import Foundation

/// The write half of the transcript tab's two edit paths (T19): the editor's line save and
/// FEAT13's Clarify confirm. Out of the View so a test can drive the one-destination rule against
/// a temp directory; `ClarifyTests` used to do the store write itself, so the switch that picks
/// the destination had no test at all.
///
/// Each method returns nil on success or the message the sheet renders inline. Logging stays with
/// the write: SEC14's split (lengths by default, the words only under verbose) travels with it.
@MainActor
struct TranscriptEditActions {
    let stem: String
    let directory: URL
    let glossaryURL: URL

    init(stem: String, directory: URL, glossaryURL: URL = GlossaryStore.defaultURL) {
        self.stem = stem
        self.directory = directory
        self.glossaryURL = glossaryURL
    }

    /// FEAT13: a confirmed clarification writes exactly one destination. "Fix this line only"
    /// writes the correction overlay and never `glossary.toml`; "Always fix this" writes the term
    /// and never the overlay. `lineOriginal` is the pipeline's text for a segment index, nil when
    /// the line is no longer on screen.
    func apply(_ plan: Clarify.Plan, lineOriginal: (Int) -> String?, lines: [String] = []) -> String? {
        switch plan {
        case .correctLine(let index, let newText):
            guard let original = lineOriginal(index) else {
                return "That line is no longer on screen. Close this and try again."
            }
            return saveLine(segmentIndex: index, pipelineOriginal: original, newText: newText)
        case .addTerm(let heard, let canonical, let workflow, _):
            return addTerm(heard: heard, canonical: canonical, workflow: workflow, lines: lines)
        }
    }

    /// The editor's save. An empty edit reverts the line: it drops the override rather than
    /// storing "", which the pipeline's reader would have applied as a blank line (T19).
    func saveLine(segmentIndex: Int, pipelineOriginal: String, newText: String) -> String? {
        let edited = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if edited.isEmpty {
                _ = try TranscriptCorrectionStore.remove(segmentIndex: segmentIndex, stem: stem, in: directory)
            } else {
                _ = try TranscriptCorrectionStore.upsert(
                    segmentIndex: segmentIndex,
                    pipelineOriginal: pipelineOriginal,
                    edited: edited,
                    stem: stem,
                    in: directory
                )
            }
        } catch {
            Log.event(category: "correction", action: "transcript_correction_failed",
                      attributes: [
                        "stem": stem,
                        "segment_index": segmentIndex,
                        "error": error.localizedDescription,
                      ])
            return error.localizedDescription
        }
        // SEC14: the event log is grepped and shared in diagnostics, so it carries lengths by
        // default, not the verbatim transcript sentences. The full text lands only under verbose.
        var attributes: [String: Any] = [
            "stem": stem,
            "segment_index": segmentIndex,
            "original_len": pipelineOriginal.count,
            "edited_len": edited.count,
        ]
        if UISettings.shared.verboseLogging {
            attributes["original_text"] = pipelineOriginal
            attributes["edited_text"] = edited
        }
        Log.event(category: "correction", action: "transcript_correction", attributes: attributes)
        return nil
    }

    /// FEAT12: the confirmed half of "Add to Vocabulary", through `GlossaryStore.addTerm`, the same
    /// append the Preferences editor's rows ride, so there is no second writer of `glossary.toml`.
    /// The store is built here so the document it merges into is read at confirm time.
    /// `lines` is the meeting's displayed lines, for FEAT25's `matches_here`; empty when the
    /// caller has none (a count of 0 then, never a guess).
    func addTerm(heard: String, canonical: String, workflow: String?, lines: [String] = []) -> String? {
        do {
            try GlossaryStore(fileURL: glossaryURL).addTerm(heard: heard, canonical: canonical, workflow: workflow)
        } catch {
            Log.event(category: "correction", action: "vocabulary_term_add_failed",
                      attributes: [
                        "stem": stem,
                        "error": error.localizedDescription,
                      ])
            return error.localizedDescription
        }
        // SEC14, the same split `transcript_correction` makes: the term comes out of a transcript
        // line, so the log carries lengths and the scope by default and the words only under verbose.
        var attributes: [String: Any] = [
            "stem": stem,
            "scope": workflow == nil ? "global" : "workflow",
            "heard_len": heard.count,
            "canonical_len": canonical.count,
        ]
        // FEAT25: the reach preview the sheet showed, and whether only capitals changed. Counts
        // and a bool, so SEC14's split holds: the words stay verbose-only below.
        let check = Clarify.ruleCheck(heard: heard, canonical: canonical, lines: lines)
        attributes["matches_here"] = check.matchesHere
        attributes["case_only"] = check.isCaseOnly
        if UISettings.shared.verboseLogging {
            attributes["heard"] = heard
            attributes["canonical"] = canonical
        }
        Log.event(category: "correction", action: "vocabulary_term_added", attributes: attributes)
        return nil
    }
}
