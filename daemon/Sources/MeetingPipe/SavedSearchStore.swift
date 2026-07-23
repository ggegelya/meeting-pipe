import Combine
import Foundation

/// Observable owner of the saved smart folders (UX24). One JSON array at
/// `~/.config/meeting-pipe/saved_searches.json`.
///
/// Deliberately the `ConsentStore` single-file-JSON idiom rather than `WorkflowStore`'s
/// file-per-item TOML: a folder is daemon UI state with no per-item override pin, the
/// pipeline never reads it, and the whole set is rewritten on any edit anyway. Mutations
/// run on the caller's queue (main, from the Library views) so `@Published` stays on the
/// main thread; the disk write hops to a private queue so the UI never blocks.
final class SavedSearchStore: ObservableObject {

    /// Rail order: `order` first, then case-insensitive name so a tie is stable.
    @Published private(set) var searches: [SavedSearch] = []

    private let url: URL
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
        guard let data = try? Data(contentsOf: url) else {
            searches = []
            return
        }
        do {
            searches = try JSONDecoder().decode([SavedSearch].self, from: data)
                .sorted(by: Self.orderComparator)
        } catch {
            // A corrupt or hand-broken file must not take the Library down with it.
            Log.main.warning("SavedSearchStore: ignoring unreadable \(self.url.lastPathComponent): \(error.localizedDescription)")
            searches = []
        }
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
        guard !trimmed.isEmpty,
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
        guard let idx = searches.firstIndex(where: { $0.id == id }) else { return false }
        searches[idx].base = base
        searches[idx].filter = filter
        persist()
        return true
    }

    @discardableResult
    func delete(id: UUID) -> Bool {
        guard let idx = searches.firstIndex(where: { $0.id == id }) else { return false }
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
                Log.main.warning("SavedSearchStore: write failed: \(error.localizedDescription)")
            }
        }
    }

    static func orderComparator(_ a: SavedSearch, _ b: SavedSearch) -> Bool {
        if a.order != b.order { return a.order < b.order }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
}
