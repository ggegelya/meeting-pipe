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

    /// On-disk locations the daemon (and pipeline) read/write.
    enum Paths {
        static let configRelative = ".config/meeting-pipe/config.toml"
        static let secretsRelative = ".config/meeting-pipe/secrets.env"
        /// Pipeline-owned self-voiceprint (FEAT3-VOICEPRINT). The daemon reads
        /// it read-only for the Preferences status + Reset; the Python pipeline
        /// owns writing it at finalize.
        static let voiceprintRelative = ".config/meeting-pipe/voiceprint.json"
        /// Pipeline-owned last-backup marker (STOR2). The daemon reads it read-only
        /// for the Preferences ▸ Storage "last backup N days ago" line (STOR3);
        /// `mp backup` owns writing it.
        static let lastBackupRelative = ".config/meeting-pipe/.last-backup.json"
        static let logsRelative = "Library/Logs/MeetingPipe"
        static let recordingsRelative = "Documents/Meetings/raw"
        /// Phase 2 correction corpus. Per-meeting JSON files; consumed by
        /// `mp corrections-stats` and (Phase 3) the LoRA trainer.
        static let correctionsRelative = "Library/Application Support/MeetingPipe/corrections"
    }
}
