import Foundation

/// Persistent "Always for {App}" choices. Spec §3 stores in
/// ~/Library/Application Support/MeetingPipe/auto_consent.json.
final class ConsentStore {
    private let url: URL
    private var bundles: Set<String>

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MeetingPipe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("auto_consent.json")

        if let data = try? Data(contentsOf: url),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            self.bundles = Set(arr)
        } else {
            self.bundles = []
        }
    }

    func isAutoConsented(bundleID: String) -> Bool {
        bundles.contains(bundleID)
    }

    func setAutoConsented(bundleID: String, value: Bool) {
        if value { bundles.insert(bundleID) } else { bundles.remove(bundleID) }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Array(bundles).sorted()) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
