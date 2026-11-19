import AppKit

/// The owner's own voice when no name is set (UX83).
///
/// The pipeline used to leave an identified owner with no `summarization.user_label` on
/// FluidAudio's raw cluster id ("1"): the cast counted it as a roster match, Rename
/// everywhere on it failed (nobody named "1" is enrolled), and summaries listed "1" as an
/// attendee. Since UX83 `diarize.resolve_speaker_labels` writes the reserved
/// `speaker_user` instead, the label the channel fallback already gives the same person.
/// This type is the Swift half: which raw labels are the owner, the word they render as,
/// and the carry that puts a name on them across past meetings.
enum OwnerName {
    /// `diarize.USER_SPEAKER`.
    static let reservedLabel = "speaker_user"
    /// What the owner reads as with no name set. `mp.markdown.speaker_word` says the same.
    static let word = "You"

    /// Whether `label` is the owner's unnamed voice: the reserved label, or, in a meeting
    /// finalized before UX83, a purely numeric cluster id that carries a voiceprint. The
    /// finalizer gives every other voice with an embedding a roster name or a `THEM-x`,
    /// so a numeric label left in `<stem>.embeddings.json` can only be the owner's.
    static func isOwnerKey(_ label: String, voiceprintLabels: Set<String>) -> Bool {
        if label == reservedLabel { return true }
        return !label.isEmpty && label.allSatisfy { $0.isASCII && $0.isNumber } && voiceprintLabels.contains(label)
    }

    /// The owner labels a meeting's transcript carries. More than one raw numeric owner key
    /// would contradict the rule `isOwnerKey` rests on (only the owner keeps a numeric id with a
    /// voiceprint), so a meeting like that keeps only `speaker_user`, if it has one: the carry
    /// writes to every past meeting, and naming two voices the owner would be the wrong write.
    static func ownerKeys(segments: [TranscriptSegment], voiceprintLabels: Set<String>) -> Set<String> {
        let keys = Set(segments.compactMap(\.speakerID).filter { isOwnerKey($0, voiceprintLabels: voiceprintLabels) })
        let numeric = keys.filter { $0 != reservedLabel }
        return numeric.count > 1 ? keys.subtracting(numeric) : keys
    }

    /// Save `name` as `summarization.user_label`. Refused (false) while config.toml does not
    /// parse: the app never saves over a file it cannot read (UX94).
    @MainActor
    @discardableResult
    static func save(_ name: String, to config: ConfigStore) -> Bool {
        guard config.parseError == nil else { return false }
        config.summarizationUserLabel = name
        return true
    }

    /// The name prompt behind **Set your name…**, prefilled with `current`. Returns the
    /// trimmed name, or nil on cancel or an empty field.
    static func prompt(current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "What should transcripts call you?"
        alert.informativeText = "Your own voice in this meeting and in your past meetings takes this name, and summaries use it too. It is saved as \"Your name\" in Preferences."
        alert.addButton(withTitle: "Set Name")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Put `name` on the owner's unnamed voice in every meeting in `directory`, through each
    /// meeting's speaker-label overlay, never `<stem>.json` (FEAT3-UNDO's rule, the
    /// `RosterRename.carry` idiom). In `currentStem` it replaces whatever name the owner's
    /// label had; elsewhere it only fills a label the owner has not named there already, so
    /// a per-meeting choice survives. `skip` names stems not to touch (a meeting being
    /// re-transcribed). Best-effort per meeting. Runs off main: it reads a transcript per
    /// meeting.
    static func carry(
        name: String,
        currentStem: String?,
        in directory: URL,
        skip: Set<String> = []
    ) -> RosterRename.Outcome {
        guard !name.isEmpty,
              let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return RosterRename.Outcome(carried: 0, failed: 0) }
        // A meeting's transcript is exactly `<stem>.json`; every sidecar has a longer suffix.
        let stems = files
            .filter { $0.hasSuffix(".json") && MeetingStore.stem(of: URL(fileURLWithPath: $0)) + ".json" == $0 }
            .map { String($0.dropLast(".json".count)) }
            .filter { !skip.contains($0) }
            .sorted()
        var carried = 0
        var failed = 0
        for stem in stems {
            guard let speech = TranscriptLoader.loadSpeech(stem: stem, in: directory) else { continue }
            let voiceprints = MeetingStore.embeddingsSidecar(stem: stem, in: directory).voiceprintLabels
            let keys = ownerKeys(segments: speech.segments, voiceprintLabels: voiceprints)
            let targets = keys.filter { stem == currentStem || speech.overlay.labels[$0] == nil }
            guard !targets.isEmpty else { continue }
            do {
                var overlay = try SpeakerLabelStore.loadForWrite(stem: stem, in: directory)
                for key in targets where stem == currentStem || overlay.labels[key] == nil {
                    overlay.labels[key] = name
                }
                try SpeakerLabelStore.replace(overlay: overlay, stem: stem, in: directory)
                carried += 1
            } catch {
                failed += 1
                Log.failure(category: "library", action: "owner_name_carry_failed", error: error,
                            attributes: ["stem": stem])
            }
        }
        return RosterRename.Outcome(carried: carried, failed: failed)
    }
}
