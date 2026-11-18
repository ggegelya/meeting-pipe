import Foundation

/// Which banner a run that finished without a failure gets (UX90). Pure over what is on disk, so
/// the precedence is assertable without a notification center.
///
/// `run-all` exits 0 for three different outcomes: a summary, a no-speech or suspect-transcript
/// skip (`<stem>.empty.json`), and a paste-bundle skip (`<stem>.READY_FOR_MANUAL.md`, the BYO and
/// too-long paths). Only the first is "processed". The paste skip used to fall through to the
/// generic done banner, which said "Meeting processed / Nothing was published" while the meeting
/// was waiting for the owner to paste a summary.
enum DoneRoute: Equatable {
    /// No summary was meant to exist: `EmptyMarker`'s honest copy.
    case empty(EmptyReason)
    /// The pipeline wrote a paste bundle and no summary.
    case pasteReady
    /// The ordinary done banner, over whatever published.
    case done

    static let pasteBundleSuffix = ".READY_FOR_MANUAL.md"

    /// The empty marker wins (it is the more specific skip), then a paste bundle with no summary.
    /// A bundle beside a summary is a paste that was already published, so it is `.done`.
    static func decide(emptyReason: EmptyReason?, hasPasteBundle: Bool, hasSummary: Bool) -> DoneRoute {
        if let emptyReason { return .empty(emptyReason) }
        if hasPasteBundle && !hasSummary { return .pasteReady }
        return .done
    }

    /// The same decision over a recordings directory: file presence, the `EmptyMarker` idiom.
    static func probe(stem: String, in dir: URL) -> DoneRoute {
        let fm = FileManager.default
        return decide(
            emptyReason: EmptyMarker.read(stem: stem, in: dir),
            hasPasteBundle: fm.fileExists(atPath: dir.appendingPathComponent(stem + pasteBundleSuffix).path),
            hasSummary: fm.fileExists(atPath: dir.appendingPathComponent("\(stem).summary.json").path)
        )
    }
}
