import Darwin
import Foundation

/// Is the meeting library sitting inside a cloud-sync folder? (SEC12)
///
/// The daemon's twin of `mp.cloudsync`. The rule set is deliberately duplicated
/// rather than shelled out to: this feeds a synchronous status pill in Preferences,
/// `mp doctor` feeds a text line, and a subprocess plus a JSON contract is more
/// machinery than the forty lines it would save. Both sides are unit-tested, and
/// the rules are written down once in CONVENTIONS.
///
/// See `cloudsync.py` for the two dead ends this does not take (resolving symlinks
/// does not reveal Desktop & Documents sync, and `MOBILE_DOCUMENTS` means iCloud
/// Drive rather than Desktop & Documents).
enum CloudSyncDetector {

    /// Stamped by macOS on `~/Documents` and `~/Desktop` under Desktop & Documents sync.
    static let iCloudDesktopAttribute = "com.apple.icloud.desktop"
    /// Present on every File Provider sync root, Apple's and third-party alike.
    static let fileProviderAttribute = "com.apple.file-provider-domain-id"

    static let unidentified = "an unidentified sync client"

    /// `~/Library/CloudStorage/OneDrive-Contoso` -> "OneDrive".
    private static let cloudStorageNames: [String: String] = [
        "iCloudDrive": "iCloud Drive",
        "GoogleDrive": "Google Drive",
        "OneDrive": "OneDrive",
        "Dropbox": "Dropbox",
        "Box": "Box",
        "Egnyte": "Egnyte",
        "pCloud": "pCloud",
        "ProtonDrive": "Proton Drive",
    ]

    /// Legacy, pre-File-Provider clients that just make a plain directory.
    private static let legacyDirectoryNames: [String: String] = [
        "Dropbox": "Dropbox",
        "Google Drive": "Google Drive",
        "GoogleDrive": "Google Drive",
        "Box Sync": "Box",
        "pCloud Drive": "pCloud",
        "Sync": "Sync.com",
    ]

    struct SyncProvider: Equatable {
        /// "iCloud Drive", "Dropbox", or `unidentified`.
        let name: String
        /// Why we think so, phrased for a user who has to act on it.
        let evidence: String
        /// The ancestor that is actually the sync root.
        let root: URL
    }

    /// The sync client that would upload `path`, or nil when it stays local.
    /// `home` is injectable so tests can build a fake home under a temp dir.
    static func detect(
        path: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> SyncProvider? {
        // Follow symlinks first: a library symlinked into a sync folder still syncs.
        let resolved = path.resolvingSymlinksInPath().standardizedFileURL
        let home = home.resolvingSymlinksInPath().standardizedFileURL
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let mobileDocuments = home.appendingPathComponent("Library/Mobile Documents", isDirectory: true)

        var ancestor = resolved
        while true {
            let parent = ancestor.deletingLastPathComponent()

            if parent.standardizedFileURL == cloudStorage {
                let provider = cloudStorageProvider(ancestor) ?? unidentified
                return SyncProvider(
                    name: provider,
                    evidence: "The library is inside the \(provider) sync folder.",
                    root: ancestor
                )
            }
            if ancestor.standardizedFileURL == mobileDocuments {
                return SyncProvider(
                    name: "iCloud Drive",
                    evidence: "The library is inside iCloud Drive.",
                    root: ancestor
                )
            }

            let attributes = extendedAttributeNames(at: ancestor)
            if attributes.contains(iCloudDesktopAttribute) {
                return SyncProvider(
                    name: "iCloud Drive",
                    evidence: "\(ancestor.lastPathComponent) is synced by iCloud's Desktop & Documents Folders setting.",
                    root: ancestor
                )
            }
            if attributes.contains(fileProviderAttribute) {
                return SyncProvider(
                    name: unidentified,
                    evidence: "\(ancestor.lastPathComponent) is managed by a macOS File Provider sync extension.",
                    root: ancestor
                )
            }

            if let legacy = legacyDirectoryNames[ancestor.lastPathComponent] {
                return SyncProvider(
                    name: legacy,
                    evidence: "The library is inside a \(legacy) folder.",
                    root: ancestor
                )
            }

            // Stop at the home directory, and at the filesystem root for a library
            // parked outside it.
            if ancestor.standardizedFileURL == home || parent.path == ancestor.path {
                return nil
            }
            ancestor = parent
        }
    }

    private static func cloudStorageProvider(_ directory: URL) -> String? {
        let prefix = directory.lastPathComponent.split(separator: "-", maxSplits: 1).first.map(String.init)
        return prefix.flatMap { cloudStorageNames[$0] }
    }

    /// Extended-attribute names on `url`. Foundation exposes no API for this, so
    /// it calls `listxattr(2)`. Any failure reads as "no attributes": the
    /// path-shape rules still catch the common cases, and a detector that throws
    /// is worse than one that misses.
    static func extendedAttributeNames(at url: URL) -> Set<String> {
        url.path.withCString { path -> Set<String> in
            let size = listxattr(path, nil, 0, 0)
            guard size > 0 else { return [] }
            var buffer = [CChar](repeating: 0, count: size)
            let read = listxattr(path, &buffer, size, 0)
            guard read > 0 else { return [] }

            var names: Set<String> = []
            var start = 0
            for index in 0..<read where buffer[index] == 0 {
                if index > start {
                    let bytes = buffer[start..<index].map { UInt8(bitPattern: $0) }
                    if let name = String(bytes: bytes, encoding: .utf8) {
                        names.insert(name)
                    }
                }
                start = index + 1
            }
            return names
        }
    }
}
