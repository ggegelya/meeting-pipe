import Foundation

/// Persistent "Always for {App}" consent store (see ARCHITECTURE.md), backed by ~/Library/Application Support/MeetingPipe/auto_consent.json.
final class ConsentStore {
    private let url: URL
    private var bundles: Set<String>

    /// `customURL` overrides the storage path for testing.
    init(url customURL: URL? = nil) {
        if let customURL = customURL {
            self.url = customURL
            try? FileManager.default.createDirectory(
                at: customURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } else {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/MeetingPipe", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.url = dir.appendingPathComponent("auto_consent.json")
        }

        switch Self.read(url) {
        case .loaded(let list):
            self.bundles = list
            self.loadFailed = false
        case .missing:
            self.bundles = []
            self.loadFailed = false
        case .unparseable, .unreadable:
            // STOR9: the empty fallback, held so the next save cannot write it over the owner's list.
            self.bundles = []
            self.loadFailed = true
        }
    }

    /// STOR9: the last load failed, so `bundles` is the empty fallback, not the owner's allowlist.
    private var loadFailed: Bool

    private static func read(_ url: URL) -> StoreLoad<Set<String>> {
        StoreLoad.read(url) { Set(try JSONDecoder().decode([String].self, from: $0)) }
    }

    func isAutoConsented(bundleID: String) -> Bool {
        bundles.contains(bundleID)
    }

    func setAutoConsented(bundleID: String, value: Bool) {
        if loadFailed {
            guard let base = StoreGuard.recoverForWrite(
                reread: Self.read(url), empty: [], url: url, store: "auto_consent", pathKind: .appSupport
            ) else { return }
            bundles = base
            loadFailed = false
        }
        if value { bundles.insert(bundleID) } else { bundles.remove(bundleID) }
        save()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(Array(bundles).sorted())
            try data.write(to: url, options: .atomic)
        } catch {
            // STOR9: was `try?`, so an "Always for this app" that never reached disk said nothing.
            Log.failure(category: "coordinator", action: "consent_save_failed", error: error, describe: false)
        }
    }
}
