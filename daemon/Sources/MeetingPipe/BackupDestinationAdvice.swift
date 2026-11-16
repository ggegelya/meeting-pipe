import Foundation

/// SEC35: what the Storage pane says when the folder chosen for backups is inside a cloud-sync folder.
///
/// An archive holds all audio, transcripts, voiceprints and the roster, NDA and regulated meetings
/// included, so a backup folder that a sync client owns uploads every one of them. The choice is not
/// refused (a synced backup folder is a legitimate choice for someone who wants offsite copies); it is
/// named, with stronger wording when this Mac promises zero egress. Pure, so it is testable without a panel.
enum BackupDestinationAdvice {

    /// The warning to show beside the chosen destination, or nil when it stays local.
    static func syncWarning(provider: CloudSyncDetector.SyncProvider?, promisesZeroEgress: Bool) -> String? {
        guard let provider else { return nil }
        if promisesZeroEgress {
            return "This backup folder is synced by \(provider.name), and regulated mode or an NDA workflow promises that nothing leaves this Mac. "
                + "Every archive here includes your recordings and transcripts, so \(provider.name) will upload them. Pick a folder outside the synced tree."
        }
        return "This backup folder is synced by \(provider.name), so every archive, recordings and transcripts included, is uploaded. "
            + "Pick a folder outside the synced tree if that is not what you want."
    }
}
