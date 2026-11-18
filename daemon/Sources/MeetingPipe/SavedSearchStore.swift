import Combine
import Foundation

/// Observable owner of the saved smart folders (UX24). One JSON array at
/// `~/.config/meeting-pipe/saved_searches.json`.
///
/// Deliberately a single-file-JSON store rather than `WorkflowStore`'s
/// file-per-item TOML: a folder is daemon UI state with no per-item override pin, the
/// pipeline never reads it, and the whole set is rewritten on any edit anyway. Mutations
/// run on the caller's queue (main, from the Library views) so `@Published` stays on the
/// main thread; the disk write hops to a private queue so the UI never blocks.
final class SavedSearchStore: ObservableObject {

    /// Rail order: `order` first, then case-insensitive name so a tie is stable.
    @Published private(set) var searches: [SavedSearch] = []

    private let url: URL
    /// STOR9: the last load failed (unparseable or unreadable), so `searches` is the empty fallback
    /// and not the owner's folders. The next mutation re-reads first (`StoreGuard.recoverForWrite`).
    private var loadFailed = false
    private let writeQueue = DispatchQueue(
        label: "com.meetingpipe.savedsearchstore.write",
        qos: .utility
    )

    /// Default location, sibling to `config.toml` and the `workflows/` directory.
    static let defaultURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/meeting-pipe/saved_searches.json")
    }()

    init(url: URL = SavedSearchStore.defaultURL) {
        self.url = url
    }

    /// Does not load on init (the `WorkflowStore` precedent): the Coordinator calls this
    /// explicitly, so a headless test that builds a `LibraryWindowModel` never reads the
    /// real file.
    func load() {
        switch Self.read(url) {
        case .loaded(let list):
            searches = list
            loadFailed = false
        case .missing:
            searches = []
            loadFailed = false
        case .unparseable(let error), .unreadable(let error):
            // A corrupt or hand-broken file must not take the Library down with it, and since STOR9
            // it must not be saved over either: `loadFailed` holds the next write until it re-reads.
            Log.failure(category: "library", action: "saved_searches_unreadable", error: error, attributes: [
                "file": self.url.lastPathComponent,
            ])
            searches = []
            loadFailed = true
        }
    }

    private static func read(_ url: URL) -> StoreLoad<[SavedSearch]> {
        StoreLoad.read(url) { data in
            try JSONDecoder().decode([SavedSearch].self, from: data).sorted(by: orderComparator)
        }
    }

    /// STOR9: every mutation asks first. False refuses it (the file could not be read; the owner
    /// was told, and nothing changed).
    private func mayWrite() -> Bool {
        guard loadFailed else { return true }
        guard let base = StoreGuard.recoverForWrite(
            reread: Self.read(url), empty: [], url: url, store: "saved_searches", pathKind: .config
        ) else { return false }
        searches = base
        loadFailed = false
        return true
    }

    func search(id: UUID) -> SavedSearch? {
        searches.first { $0.id == id }
    }

    /// Order slot for the next folder, so a new one lands at the bottom of the rail.
    var nextOrder: Int {
        (searches.map(\.order).max() ?? -1) + 1
    }

    /// True when `name` is already taken (case-insensitive), ignoring `excluding`.
    /// The rail resolves a folder by id, so a duplicate is legal; the naming sheet uses
    /// this only to warn, since two identically-named rail rows are unreadable (WF9).
    func isNameTaken(_ name: String, excluding: UUID? = nil) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return searches.contains {
            $0.id != excluding && $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    /// Insert or replace by id, then persist.
    func upsert(_ search: SavedSearch) {
        guard mayWrite() else { return }
        if let idx = searches.firstIndex(where: { $0.id == search.id }) {
            searches[idx] = search
        } else {
            searches.append(search)
        }
        searches.sort(by: Self.orderComparator)
        persist()
    }

    @discardableResult
    func rename(id: UUID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, mayWrite(),
              let idx = searches.firstIndex(where: { $0.id == id })
        else { return false }
        searches[idx].name = trimmed
        searches.sort(by: Self.orderComparator)
        persist()
        return true
    }

    /// Replace a folder's base + filter with the view the user is looking at now
    /// ("Update to current filter" on the rail row).
    @discardableResult
    func updateCriteria(id: UUID, base: SavedSearch.Base, filter: MeetingFilter) -> Bool {
        guard mayWrite(), let idx = searches.firstIndex(where: { $0.id == id }) else { return false }
        searches[idx].base = base
        searches[idx].filter = filter
        persist()
        return true
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        guard mayWrite(), let idx = searches.firstIndex(where: { $0.id == id }) else { return false }
        searches.remove(at: idx)
        persist()
        return true
    }

    // MARK: - Disk

    private func persist() {
        let snapshot = searches
        let target = url
        writeQueue.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(snapshot) else { return }
            do {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: target, options: .atomic)
            } catch {
                Log.failure(category: "library", action: "saved_searches_write_failed", error: error)
            }
        }
    }

    static func orderComparator(_ a: SavedSearch, _ b: SavedSearch) -> Bool {
        if a.order != b.order { return a.order < b.order }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}
