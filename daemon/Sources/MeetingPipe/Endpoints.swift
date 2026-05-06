import Foundation

/// Daemon-side identifiers and external paths.
///
/// External API URLs (Notion / Anthropic / HuggingFace) live on the pipeline
/// side because the daemon never calls them — it spawns `mp` subprocesses
/// instead. This file collects the daemon-only constants so a rename or
/// path change is a one-file edit.
enum Endpoints {
    /// CFBundleIdentifier; matches `scripts/install.sh` Info.plist + LaunchAgent label.
    static let bundleID = "com.meetingpipe.daemon"

    /// Resource name (without extension) used for `CFBundleIconFile` and
    /// loaded by `NSImage(named:)` from the .app's Resources/.
    static let appIconResource = "AppIcon"

    /// `subsystem` used by every `os_log` channel in `Logger.swift`.
    static let logSubsystem = bundleID

    /// Where the LaunchAgent lives, relative to the user's home dir.
    /// Single source of truth used by both install.sh's heredoc and the
    /// daemon's `mp doctor` cross-reference.
    static let launchAgentLabel = bundleID

    /// On-disk locations the daemon (and pipeline) read/write.
    enum Paths {
        static let configRelative = ".config/meeting-pipe/config.toml"
        static let secretsRelative = ".config/meeting-pipe/secrets.env"
        static let logsRelative = "Library/Logs/MeetingPipe"
        static let recordingsRelative = "Documents/Meetings/raw"
        /// Phase 2 correction corpus. Per-meeting JSON files; consumed by
        /// `mp corrections-stats` and (Phase 3) the LoRA trainer.
        static let correctionsRelative = "Library/Application Support/MeetingPipe/corrections"
    }
}
