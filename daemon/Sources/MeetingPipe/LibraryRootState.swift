import Foundation

/// What a scan found at the library root (UX89). One type for every root question, so the Library,
/// the background sweeps and doctor read the same answer rather than each treating a failed listing
/// as an empty library.
enum LibraryRootState: Equatable {
    /// The root listed. It may hold no meetings; that is the first-run empty list.
    case readable
    /// Nothing exists at the configured path: a typo, an unmounted volume, or a library moved or
    /// deleted outside the app. The Library names the path and offers to choose a folder.
    case missing

    /// The state a failed listing means.
    static func afterFailedListing(exists: Bool) -> LibraryRootState {
        exists ? .readable : .missing
    }

    /// Whether the Library may create a missing root when it starts watching. Only the first-run
    /// default, and never a root the app has re-rooted away from: creating that one would put an
    /// empty folder back where a move just took the library from (F058), and creating any other
    /// would turn a typo or an unmounted volume into an empty library that hides the real one.
    static func mayCreate(root: URL, creatableRoot: URL?, departed: Set<URL>, exists: Bool) -> Bool {
        guard !exists, let creatableRoot else { return false }
        let root = root.standardizedFileURL
        guard root == creatableRoot.standardizedFileURL else { return false }
        return !departed.contains(root)
    }
}

/// Which placeholder the Library list shows, if any (UX89). Pure, so the choice between the
/// first-run empty state and the missing-root state is tested without rendering a view.
enum LibraryListPlaceholder: Equatable {
    case loading
    case firstRun
    case missingRoot(path: String)
    /// There are meetings; no placeholder.
    case none

    static func decide(
        hasLoadedOnce: Bool, isEmpty: Bool, rootState: LibraryRootState, root: URL
    ) -> LibraryListPlaceholder {
        guard hasLoadedOnce else { return .loading }
        guard isEmpty else { return .none }
        switch rootState {
        case .readable: return .firstRun
        case .missing: return .missingRoot(path: (root.path as NSString).abbreviatingWithTildeInPath)
        }
    }
}
