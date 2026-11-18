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

    /// The default a config that names no path gets: the old one while it holds files, else the
    /// new one. Applied to the in-memory value as well as written by the pin, so a `config.toml`
    /// that does not parse (the store then runs on defaults and writes nothing) still records into
    /// the library the owner has, not an empty new folder; and so does every `ConfigStore()` reader
    /// that never runs the pin (the `doctor` subcommand, `RosterRename`).
    static func effectiveDefault(_ key: Key, hasEntries: (String) -> Bool) -> String {
        hasEntries(key.legacy) ? key.legacy : key.current
    }

    /// The production check. Under XCTest it reads nothing and answers false, the way `Log`
    /// redirects its directory there: a developer's Mac holds a real library at the old default,
    /// and a suite that read it would see the old default wherever it expects the new one. A test
    /// that wants the old library injects its own.
    static let defaultHasEntries: @Sendable (String) -> Bool = { path in
        Log.isRunningUnderTests ? false : hasEntries(path)
    }

    /// Whether `path` (tilde allowed) is a directory with at least one entry.
    static func hasEntries(_ path: String, fileManager: FileManager = .default) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        guard let entries = try? fileManager.contentsOfDirectory(atPath: expanded) else { return false }
        return entries.contains { $0 != ".DS_Store" }
    }
}
