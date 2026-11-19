import Foundation

/// `<stem>.overlay_backup.json` (ASR12): both overlay sidecars exactly as they were on disk
/// before a re-transcribe's carry rewrote them, plus the transcript anchors they were keyed
/// against.
///
/// The carry drops and counts what it cannot place, and on a failed finalize it deliberately
/// leaves cluster names out of the written sidecar (they would key on raw labels the Reprocess
/// finalize is about to change). Counted is not recoverable, so this is the copy a later carry,
/// or the owner by hand, can recover a dropped name or edit from. Nothing reads it yet; a
/// restore UI is out of ASR12's scope.
///
/// One file per stem, replaced by each carry that writes, so it always describes the state the
/// last carry started from. It is a stem file like the others, so a delete or a library move
/// takes it along by prefix (`MeetingStore.stem(of:)`).
///
/// Schema: `{schema_version: 1, written_at, speaker_labels: <object|null>,
/// transcript_corrections: <object|null>, anchors: [{index, start, end, speaker, text}]}`.
enum OverlayBackup {

    static let schemaVersion = 1

    static func path(stem: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(stem).overlay_backup.json")
    }

    /// Write the backup. `anchors` are the transcript the sidecars were keyed against (the
    /// request-time `<stem>.json`). A sidecar that is missing is recorded as null; one that
    /// is present but not a JSON object never gets here, because the carry's `StoreGuard`
    /// read refuses it first.
    static func write(
        stem: String,
        in directory: URL,
        anchors: [TranscriptOverlayCarry.Anchor],
        now: Date = Date()
    ) throws {
        func object(_ url: URL) -> Any {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return NSNull()
            }
            return obj
        }
        let payload: [String: Any] = [
            "schema_version": schemaVersion,
            "written_at": ISO8601.format(now),
            "speaker_labels": object(SpeakerLabelStore.path(stem: stem, in: directory)),
            "transcript_corrections": object(TranscriptCorrectionStore.path(stem: stem, in: directory)),
            "anchors": anchors.map { a -> [String: Any] in
                var row: [String: Any] = ["index": a.index, "start": a.start, "end": a.end, "text": a.text]
                if let speaker = a.speaker { row["speaker"] = speaker }
                return row
            },
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: path(stem: stem, in: directory), options: .atomic)
    }
}
