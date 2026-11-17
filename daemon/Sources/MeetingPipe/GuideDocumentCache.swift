import Foundation
import os

/// PERF29: the bundled guide, read, parsed and inline-rendered once per process, off main.
///
/// The bundled `GUIDE.md` cannot change while the process runs, but `GuideView.load()` re-read
/// 63.5 KB and ran about 264 inline-markdown parses on main from `onAppear`, on
/// every open (the window was rebuilt on every open too). The first request starts the build on
/// a background queue and every later one is served from memory; a request made while the
/// build runs waits for it rather than starting a second.
///
/// `read` and `queue` are injectable so a test can see that the build runs off main and that
/// the bundle is read once. The result is what `GuideView` used to compute in `load()`:
/// `rendered(parse(markdown))` and `sections(of:)`.
final class GuideDocumentCache: Sendable {

    static let shared = GuideDocumentCache()

    struct Loaded: Equatable, Sendable {
        let blocks: [GuideDocument.RenderedBlock]
        let sections: [GuideDocument.Section]
    }

    private struct State {
        var loaded: Loaded?
        var building = false
        var waiters: [@Sendable (Loaded) -> Void] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let read: @Sendable () -> String?
    private let queue: DispatchQueue

    init(
        read: @escaping @Sendable () -> String? = { GuideDocument.bundledMarkdown() },
        queue: DispatchQueue = .global(qos: .userInitiated)
    ) {
        self.read = read
        self.queue = queue
    }

    /// The finished document, or nil while it has not been built yet.
    var cached: Loaded? { state.withLock { $0.loaded } }

    /// Start the build now if nothing has. A cold window open calls this before it builds its
    /// own view, so the parse overlaps the window build instead of following it.
    func prewarm() {
        startBuildIfNeeded()
    }

    /// Delivers the document on the main queue: immediately when it is already built and the
    /// caller is on main, so a re-open paints the real content on its first frame.
    func load(_ completion: @escaping @Sendable (Loaded) -> Void) {
        let ready: Loaded? = state.withLock { s in
            if let loaded = s.loaded { return loaded }
            s.waiters.append(completion)
            return nil
        }
        if let ready {
            if Thread.isMainThread { completion(ready) } else { DispatchQueue.main.async { completion(ready) } }
            return
        }
        startBuildIfNeeded()
    }

    func loaded() async -> Loaded {
        await withCheckedContinuation { continuation in
            load { continuation.resume(returning: $0) }
        }
    }

    private func startBuildIfNeeded() {
        let start = state.withLock { s -> Bool in
            guard s.loaded == nil, !s.building else { return false }
            s.building = true
            return true
        }
        guard start else { return }
        queue.async { [self] in
            let markdown = read() ?? GuideDocument.missingCopy
            let parsed = GuideDocument.parse(markdown)
            let built = Loaded(blocks: GuideDocument.rendered(parsed), sections: GuideDocument.sections(of: parsed))
            let waiters = state.withLock { s -> [@Sendable (Loaded) -> Void] in
                s.loaded = built
                s.building = false
                defer { s.waiters = [] }
                return s.waiters
            }
            guard !waiters.isEmpty else { return }
            DispatchQueue.main.async { waiters.forEach { $0(built) } }
        }
    }
}
