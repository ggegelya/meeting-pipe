import AVFoundation
import Foundation

/// SEC22: the library's audio is owner-only from the moment it exists, and so are the folders
/// the library creates. SEC14 did this for the text artifacts; on 2026-11-12 every recording
/// was still `-rw-r--r--` in `drwxr-xr-x` folders, and the default library (`~/Meetings/raw`)
/// is outside `~/Documents`' 0700, so nothing else kept it private.
///
/// The three ways audio gets written each take the strongest route its API allows:
/// `AVAudioFile` has no mode parameter, so the file is pre-created 0600 and opened over (it
/// truncates and keeps the mode, measured 2026-11-26 and pinned by `OwnerOnlyFilesSEC22Tests`);
/// ffmpeg has no mode flag either, so its temp is tightened before it is promoted onto the
/// canonical name, which therefore never exists at 0644. No process-wide `umask`: it would reach
/// every `mp` child and everything it writes. `MeetingStore.tightenArtifactPermissions` is the
/// launch-time self-heal for files and folders that predate this.
enum OwnerOnlyFiles {

    /// `AVAudioFile(forWriting:)` at 0600. A failed pre-create is not fatal: the open still runs,
    /// the file lands at the umask, and the next launch's sweep tightens it.
    static func openAudioForWriting(at url: URL, settings: [String: Any]) throws -> AVAudioFile {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        return try AVAudioFile(forWriting: url, settings: settings)
    }

    /// Tighten one file to 0600. Best effort; false when the chmod did not apply.
    @discardableResult
    static func restrict(_ url: URL) -> Bool {
        (try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)) != nil
    }

    /// Create a library folder and every missing folder above it at 0700. A folder that already
    /// exists is left as it is (`createDirectory`'s attributes apply only to what it creates).
    static func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }
}
