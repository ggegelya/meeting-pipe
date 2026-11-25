import Foundation

/// Daemon-side identifiers and paths. External API URLs live in the pipeline (the daemon spawns `mp` subprocesses instead of calling them directly).
enum Endpoints {
    /// CFBundleIdentifier; matches `scripts/install.sh` Info.plist + LaunchAgent label.
    static let bundleID = "com.meetingpipe.daemon"

    /// Resource name (without extension) used for `CFBundleIconFile` and
    /// loaded by `NSImage(named:)` from the .app's Resources/.
    static let appIconResource = "AppIcon"

    /// `subsystem` used by every `os_log` channel in `Logger.swift`.
    static let logSubsystem = bundleID

    /// LaunchAgent label: single source of truth for install.sh and `mp doctor`.
    static let launchAgentLabel = bundleID

    /// On-disk locations the daemon (and pipeline) read/write. The app's folders are spelled here and
    /// nowhere else; `truth_fences.py sources` fails a hand-spelled one under `daemon/Sources` (ARCH18).
    enum Paths {
        /// `~/.config/meeting-pipe`: config, secrets, workflows and the owner's other editable state.
        static let configDirRelative = ".config/meeting-pipe"
        /// `~/Library/Application Support/MeetingPipe`: app-private state the owner does not edit.
        static let appSupportRelative = "Library/Application Support/MeetingPipe"
        /// `~/Library/Caches/MeetingPipe`: rebuildable caches (search index, waveform peaks, durations).
        static let cachesRelative = "Library/Caches/MeetingPipe"

        static let configRelative = configDirRelative + "/config.toml"
        static let secretsRelative = configDirRelative + "/secrets.env"
        /// Pipeline-owned self-voiceprint (FEAT3-VOICEPRINT). The daemon reads
        /// it read-only for the Preferences status + Reset; the Python pipeline
        /// owns writing it at finalize.
        static let voiceprintRelative = configDirRelative + "/voiceprint.json"
        /// Pipeline-owned named-speaker roster (FEAT3-ROSTER). The daemon reads it
        /// read-only for the Preferences ▸ Pipeline "People" list (FEAT3-MANAGE);
        /// every mutation goes through `mp roster`, so the matching logic keeps one owner.
        static let rosterRelative = configDirRelative + "/roster.json"
        /// Custom ASR vocabulary (ASR1), read by `mp.glossary` at finalize and edited
        /// in-app by Preferences ▸ Pipeline ▸ Vocabulary (FEAT11). Unlike the roster
        /// and the voiceprint the daemon writes this one, through `GlossaryStore`'s
        /// TOML round-trip; the pipeline only reads it. `glossary.example.toml` at the
        /// repo root stays the documented reference.
        static let glossaryRelative = configDirRelative + "/glossary.toml"
        /// Pipeline-owned last-backup marker (STOR2). The daemon reads it read-only
        /// for the Preferences ▸ Storage "last backup N days ago" line (STOR3);
        /// `mp backup` owns writing it.
        static let lastBackupRelative = configDirRelative + "/.last-backup.json"
        static let logsRelative = "Library/Logs/MeetingPipe"
        /// Phase 2 correction corpus. Per-meeting JSON files; consumed by
        /// `mp corrections-stats` and (Phase 3) the LoRA trainer.
        static let correctionsRelative = appSupportRelative + "/corrections"

        /// The folders resolved from home, the way every `Paths` reader resolves. Not
        /// `FileManager.urls(for:)`: the app is not sandboxed, so both name the same folder, and one
        /// spelling is the point.
        static var configDir: URL { home.appendingPathComponent(configDirRelative, isDirectory: true) }
        static var appSupportDir: URL { home.appendingPathComponent(appSupportRelative, isDirectory: true) }
        static var cachesDir: URL { home.appendingPathComponent(cachesRelative, isDirectory: true) }

        private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    }
}
