import SwiftUI

/// UX98: which meeting a detail view is showing right now, read after an `await`.
///
/// The detail tabs load off main and then write the result into `@State`. Their old guard,
/// `let stem = meeting.stem` before the await and `meeting.stem == stem` after it, compared a
/// value with itself: `meeting` is a `let` of a value type on the view struct, and the async
/// function reads the copy it started with. So a load for the meeting just left landed in the
/// pane of the one now selected, a correction made there went to the wrong sidecar, and
/// Revert could write one meeting's original summary over another's.
///
/// A reference held in `@State` is the live answer: the view updates it on appear, on a stem
/// change and on disappear, and the continuation reads the same object after its await.
/// `Task.isCancelled` covers the `.task(id:)` case too, since `Task.detached(...).value` does
/// not throw on cancellation.
@MainActor
final class DetailLiveness {
    private(set) var stem: String?

    nonisolated init() {}

    func show(_ stem: String) { self.stem = stem }
    func hide() { stem = nil }

    func isShowing(_ stem: String) -> Bool { self.stem == stem }

    /// Whether a result loaded for `stem` may be written into the view: the view still shows
    /// that meeting and the task that loaded it was not cancelled.
    func accepts(_ stem: String, cancelled: Bool) -> Bool {
        !cancelled && isShowing(stem)
    }
}

extension View {
    /// UX98: keep `liveness` naming the meeting this view shows, for as long as it is on screen.
    func tracksLiveStem(_ liveness: DetailLiveness, stem: String) -> some View {
        self
            .onAppear { liveness.show(stem) }
            .onChange(of: stem) { _, new in liveness.show(new) }
            .onDisappear { liveness.hide() }
    }
}

/// UX98: where a finished summary preview lands. `runPreview` awaits a subprocess that can
/// outlast the selection; the candidate it wrote belongs to the meeting it ran for, so when
/// that meeting is no longer on screen the candidate is discarded instead of appearing beside
/// another meeting's summary with Keep and Discard aimed at the wrong stem.
enum SummaryPreviewLanding: Equatable {
    /// Show the candidate (or the error) in this pane.
    case land
    /// The pane moved on: delete the candidate the run wrote for `stem`, show nothing.
    case discardOrphan(stem: String)
    /// The pane moved on and the run wrote nothing worth deleting.
    case drop

    @MainActor
    static func decide(ranFor stem: String, succeeded: Bool, liveness: DetailLiveness) -> SummaryPreviewLanding {
        if liveness.isShowing(stem) { return .land }
        return succeeded ? .discardOrphan(stem: stem) : .drop
    }
}
