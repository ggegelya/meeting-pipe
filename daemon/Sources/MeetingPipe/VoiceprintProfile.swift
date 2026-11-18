import Foundation

/// Read-only view of the pipeline-owned self-voiceprint
/// (`~/.config/meeting-pipe/voiceprint.json`), surfaced in Preferences so the
/// user can see the auto-learned profile and reset it. The Python pipeline owns
/// writing it at finalize; the daemon only reads the meeting count and offers a
/// Reset. Not part of the `<stem>.meta.json` Swift-to-Python contract, this is a
/// display-only surface over shared per-user state (like `config.toml`).
enum VoiceprintProfile {

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(Endpoints.Paths.voiceprintRelative)
    }

    /// Number of meetings folded into the voiceprint, or 0 when not yet enrolled
    /// (absent / malformed / no embedding). Pure over the URL for testability.
    static func meetingsLearned(at url: URL = fileURL) -> Int {
        guard
            let data = try? Data(contentsOf: url),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let embedding = obj["embedding"] as? [Any], !embedding.isEmpty,
            let meetings = obj["meetings"] as? Int, meetings > 0
        else { return 0 }
        return meetings
    }

    /// Forget the learned voiceprint (the Preferences "Reset" action). The next
    /// stereo meeting re-enrolls from scratch. A file already gone is success. STOR7 (SW-18):
    /// this was `try?`, and Preferences showed "0 meetings" while the biometric file stayed.
    @discardableResult
    static func reset(at url: URL = fileURL) -> Result<Void, Error> {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Nothing to forget.
        } catch {
            Log.failure(category: "coordinator", action: "voiceprint_reset", error: error,
                        attributes: ["ok": false], describe: false)
            return .failure(error)
        }
        Log.event(category: "coordinator", action: "voiceprint_reset", attributes: ["ok": true])
        return .success(())
    }
}
