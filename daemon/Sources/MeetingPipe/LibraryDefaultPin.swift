import Foundation

/// STOR6 item 2: moving the default library out of `~/Documents` must never move an existing
/// library. The new default (`~/Meetings/raw`, outside iCloud Desktop & Documents and outside the
/// TCC-protected Documents folder) applies to a config that names no `output_dir`; for such a
/// config whose old default directory already holds files, the first launch writes the old path
/// into `config.toml` explicitly, so the library cannot appear to vanish. Every install made by
/// `install.sh` seeds the key, so this is the rare hand-made or trimmed config.
///
/// `mp.config` applies the same rule when it reads a config with no key, so a pipeline run before
/// the daemon's first launch agrees with it, and `scripts/lib/live-recording.sh` does too.
enum LibraryDefaultPin {

    /// One pinnable key: the TOML table and key, the old default, and the new one.
    struct Key: Equatable {
        let table: String
        let key: String
        let legacy: String
        let current: String
    }

    static let recordings = Key(
        table: "recording", key: "output_dir",
        legacy: ConfigDefaults.legacyOutputDirPath, current: ConfigDefaults.outputDirPath
    )
    static let published = Key(
        table: "filesystem", key: "output_dir",
        legacy: ConfigDefaults.legacyFilesystemOutputDirPath, current: ConfigDefaults.filesystemOutputDirPath
    )

    /// Pin the old default when the config names nothing and the old default holds files.
    static func shouldPin(configNamesKey: Bool, legacyHasEntries: Bool) -> Bool {
        !configNamesKey && legacyHasEntries
    }

    /// Whether `path` (tilde allowed) is a directory with at least one entry.
    static func hasEntries(_ path: String, fileManager: FileManager = .default) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        guard let entries = try? fileManager.contentsOfDirectory(atPath: expanded) else { return false }
        return entries.contains { $0 != ".DS_Store" }
    }
}
