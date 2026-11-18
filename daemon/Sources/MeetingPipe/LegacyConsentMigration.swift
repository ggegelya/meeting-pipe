import Foundation

/// UX97: the one-time move of the old "Always for {App}" list into `recording.auto_consent_apps`.
///
/// Until UX97 the prompt's Always pick wrote the bundle to
/// `~/Library/Application Support/MeetingPipe/auto_consent.json` (`ConsentStore`), a second list the
/// start check honoured and Preferences never showed: after one Always pick the allowlist read "No
/// apps yet - every meeting will prompt" while that app recorded unprompted, and nothing in the app
/// could undo it. The pick now writes `ConfigStore.autoConsentApps`, the list Preferences renders
/// with a remove tag, and this moves whatever the old file held onto it once.
///
/// "Once" rests on retiring the file, not on a contains check: the file is removed only after the
/// config write landed, so a bundle the owner later removes in Preferences stays removed at the
/// next launch. Run from the app's launch path only (`App.swift`), never from `Coordinator`, which
/// tests construct: a default-path run there would rewrite the owner's real config.
enum LegacyConsentMigration {
    enum Outcome: Equatable {
        /// No legacy file: a fresh install, or one already migrated.
        case nothing
        /// The file's bundles are in the config (`added` were new to it) and the file is gone.
        case migrated(added: Int)
        /// config.toml cannot be read, so nothing can be saved to it; the file is kept for a later launch.
        case keptConfigUnreadable
        /// The config write failed; the file is kept for a later launch.
        case keptSaveFailed
        /// The legacy file could not be opened (an I/O error); it is kept for a later launch.
        case keptLegacyUnreadable
        /// The legacy file is not a JSON list; it was moved aside as `<name>.corrupt-<stamp>`.
        case quarantined
    }

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MeetingPipe/auto_consent.json")
    }

    @discardableResult
    static func run(legacyURL: URL = defaultURL, into store: ConfigStore) -> Outcome {
        let load = StoreLoad<[String]>.read(legacyURL) { try JSONDecoder().decode([String].self, from: $0) }
        switch load {
        case .missing:
            return .nothing
        case .unreadable(let error):
            // STOR9: retryable, so leave it; a later launch migrates it.
            _ = StoreGuard.refuse(url: legacyURL, error: error, store: "auto_consent", pathKind: .appSupport)
            return .keptLegacyUnreadable
        case .unparseable(let error):
            // Nothing in it can be migrated; moving it aside keeps the bytes and says where they went.
            try? StoreGuard.quarantineForWrite(url: legacyURL, error: error, store: "auto_consent", pathKind: .appSupport)
            return .quarantined
        case .loaded(let bundles):
            guard store.parseError == nil else {
                Log.failure(category: "coordinator", action: "auto_consent_migration_failed",
                            reason: "config.toml cannot be read, so the old Always list stays where it is until it can")
                return .keptConfigUnreadable
            }
            let added = bundles.sorted().filter { store.addAutoConsentApp($0) }.count
            if added > 0 {
                do {
                    try store.saveNow()
                } catch {
                    Log.failure(category: "coordinator", action: "auto_consent_migration_failed", error: error, describe: false)
                    return .keptSaveFailed
                }
            }
            do {
                try FileManager.default.removeItem(at: legacyURL)
            } catch {
                // The bundles are in the config; a file left behind only re-adds them next launch.
                Log.failure(category: "coordinator", action: "auto_consent_migration_failed", error: error, describe: false)
            }
            Log.event(category: "coordinator", action: "auto_consent_migrated", attributes: ["count": added])
            return .migrated(added: added)
        }
    }
}
