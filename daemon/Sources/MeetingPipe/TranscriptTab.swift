import AppKit
import Combine
import SwiftUI

/// Speaker-labeled transcript with click-to-seek and current-line highlight (TECH-A6). Segments from `<stem>.json`, written by the daemon's FluidAudio runner in the long-standing `{start, end, text, speaker?}` shape (inherited from the whisperx era, kept when ASR moved to Swift). Uses the parent-owned `AudioPlaybackController` shared with the Audio tab (A7) so flipping tabs keeps the same play head.

// MARK: - Segment model

/// One parsed transcript segment.
struct TranscriptSegment: Identifiable, Hashable {
    let index: Int
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    /// Raw speaker label from the JSON (e.g. `"speaker_0"`). nil when diarization was disabled or failed.
    let speakerID: String?

    var id: Int { index }

    /// True when `time` falls within `[start, end)`. Half-open so adjacent segments don't both claim the boundary tick.
    func contains(_ time: TimeInterval) -> Bool {
        return time >= start && time < end
    }
}

enum TranscriptSegmentLookup {
    /// Index of the segment containing `time`. Gaps (silence, etc.) return the last segment before `time` so the UI keeps a row highlighted. Returns nil only when the array is empty or `time` precedes the first segment.
    static func index(at time: TimeInterval, in segments: [TranscriptSegment]) -> Int? {
        guard !segments.isEmpty else { return nil }
        if time < segments[0].start { return nil }
        // Binary search; pipeline output is sorted by start time.
        var lo = 0
        var hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if segments[mid].start <= time {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo
    }
}

/// Anchors flagged-moment markers (FEAT8) to the transcript segments they fall
/// in, so the tab can render a chip inline at each moment. Pure so it is unit
/// testable without the view.
enum TranscriptMarkerLayout {
    /// Map a segment's stable `.index` -> sorted marker offsets anchored to it.
    /// A marker before the first segment (or into a gap) anchors to the nearest
    /// segment at or before it, falling back to the first segment. Keyed by the
    /// segment id (not array position) so it composes with the row's `seg.index`
    /// even when empty segments were filtered out.
    static func assign(markers: [Double], to segments: [TranscriptSegment]) -> [Int: [Double]] {
        guard !segments.isEmpty else { return [:] }
        var out: [Int: [Double]] = [:]
        for t in markers.sorted() {
            let pos = TranscriptSegmentLookup.index(at: t, in: segments) ?? 0
            out[segments[pos].index, default: []].append(t)
        }
        return out
    }
}

/// Loads `<stem>.json` off-main and overlays transcript corrections.
enum TranscriptLoader {
    struct Result {
        let segments: [TranscriptSegment]
        let language: String?
        let speakerOrder: [String]   // speaker IDs in first-seen order
        /// Reversible speaker-label overrides (FEAT3-UNDO / FEAT3-SEGMENT). Resolved
        /// at display time, not baked into `segments`, so the raw diarization label
        /// stays recoverable. `.empty` from `parse` (no sidecar in a raw payload).
        var speakerOverlay: SpeakerLabelStore.Overlay = .empty
        /// Diarization clusters that carry a voiceprint in `<stem>.embeddings.json`,
        /// i.e. the labels `mp roster enroll` can actually enroll. A label absent
        /// here (a `speaker_unknown` junk-drawer line, a raw id that never clustered)
        /// has no voice to remember, so the row offers per-line assignment instead of
        /// cluster enrollment. Enrolling one used to hard-fail with "pipeline exited 2".
        var voiceprintLabels: Set<String> = []
        /// FEAT14: for a cluster the roster declined, the person it came closest to,
        /// from the same sidecar. Offered on the chip menu as a suggestion; nothing
        /// here writes it.
        var nearMisses: [String: String] = [:]
    }

    static func path(stem: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(stem).json")
    }

    /// Modification dates of the per-meeting sidecars the transcript pane renders,
    /// in a fixed order so two fingerprints compare positionally (UX52). A `nil`
    /// entry is a file that is not there, which is itself a state worth noticing:
    /// undoing a naming deletes the overlay sidecar.
    ///
    /// It covers every sidecar `TranscriptTab.reload` reads, not just the
    /// transcript. An in-app rename or a per-line reassignment writes only the
    /// speaker overlay, so a guard watching `<stem>.json` alone would skip exactly
    /// the refresh it exists to allow. `<stem>.embeddings.json` is left out on
    /// purpose: its only writer is `mp finalize`, which rewrites the transcript in
    /// the same pass, so the first entry already moves whenever it does.
    static func fingerprint(stem: String, in directory: URL) -> [Date?] {
        let paths = [
            path(stem: stem, in: directory),
            SpeakerLabelStore.path(stem: stem, in: directory),
            TranscriptCorrectionStore.path(stem: stem, in: directory),
            MarkerFile.path(stem: stem, in: directory),
        ]
        return paths.map { url in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }
    }

    static func load(stem: String, in directory: URL) -> Result? {
        let url = path(stem: stem, in: directory)
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let parsed = parse(obj)
        let corrections = TranscriptCorrectionStore.read(stem: stem, in: directory)
        let overlaid = TranscriptCorrectionStore.apply(
            corrections: corrections,
            to: parsed.segments
        )
        return Result(
            segments: overlaid,
            language: parsed.language,
            speakerOrder: parsed.speakerOrder,
            speakerOverlay: SpeakerLabelStore.read(stem: stem, in: directory),
            voiceprintLabels: MeetingStore.voiceprintLabels(stem: stem, in: directory),
            nearMisses: MeetingStore.nearMisses(stem: stem, in: directory)
        )
    }

    /// Parses the transcript JSON payload. Internal so tests can drive it directly.
    static func parse(_ obj: [String: Any]) -> Result {
        let language = obj["language"] as? String
        var out: [TranscriptSegment] = []
        var order: [String] = []
        var seen: Set<String> = []
        if let arr = obj["segments"] as? [[String: Any]] {
            out.reserveCapacity(arr.count)
            for (i, raw) in arr.enumerated() {
                guard let start = (raw["start"] as? NSNumber)?.doubleValue,
                      let end = (raw["end"] as? NSNumber)?.doubleValue,
                      let text = raw["text"] as? String else {
                    continue
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                let speaker = raw["speaker"] as? String
                if let s = speaker, !seen.contains(s) {
                    seen.insert(s)
                    order.append(s)
                }
                out.append(TranscriptSegment(
                    index: i,
                    start: start,
                    end: max(end, start + 0.001),
                    text: trimmed,
                    speakerID: speaker
                ))
            }
        }
        return Result(
            segments: out,
            language: (language?.isEmpty == true) ? nil : language,
            speakerOrder: order
        )
    }
}

// MARK: - Display helpers

enum TranscriptDisplay {
    /// Maps `"speaker_0"` to `"Speaker 1"` (one-based for human readability).
    static func displayName(for speakerID: String?) -> String {
        guard let id = speakerID, !id.isEmpty else { return "Unknown" }
        // The diarizer's catch-all bucket. Without this it fell through to the
        // pass-through below and rendered the raw internal id, so the transcript
        // showed literal "speaker_unknown" rows to the user.
        if id == "speaker_unknown" { return "Unknown speaker" }
        if id.hasPrefix("speaker_"),
           let n = Int(id.dropFirst("speaker_".count)) {
            return "Speaker \(n + 1)"
        }
        if id.hasPrefix("THEM-") {
            let letter = id.dropFirst("THEM-".count)
            return letter.isEmpty ? "Unknown" : "Unknown \(letter)"
        }
        return id
    }

    /// The tint for one speaker: their slot in the meeting's cast, from
    /// `MeetingCast.colorIndex`, wrapped over the palette (UX58).
    ///
    /// Stable per speaker across launches, and distinct per person while the cast is at
    /// or under the palette's eight, neither of which the hash-of-the-raw-label rule
    /// before it managed. The doc comment it replaced promised stability and delivered
    /// it only within one process. `nil` is the muted tint: a line with no speaker, or a
    /// name that is nobody in this meeting's cast.
    static func color(atCastIndex index: Int?) -> Color {
        // No `abs` here on purpose: the old rule's `abs(id.hashValue)` traps on
        // `Int.min`, and a cast position needs no rescuing to begin with.
        guard let index, index >= 0 else { return Color(MPColors.fgMuted) }
        let palette = MPColors.speakerPalette
        return Color(nsColor: palette[index % palette.count])
    }

    /// `mm:ss` / `h:mm:ss` - matches the Library row duration format.
    static func timestamp(_ time: TimeInterval) -> String {
        let total = Int(time.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Transcript tab view

/// A speaker label the roster naming sheet is open for (FEAT3-ROSTER). `currentName`
/// is set when re-opening to rename an already-named speaker (FEAT3-UNDO); nil for a
/// first naming.
struct NamingTarget: Identifiable {
    let label: String
    var currentName: String? = nil
    var id: String { label }

    /// Which sheet this target opens. Carrying a current name is what makes it a rename;
    /// without one it is a first naming. The rule lives here rather than inline in the
    /// sheet's `mode:` argument because the cast strip could only ever build the second
    /// kind (UX40), so a chip that was already named had no way to reach the rename the
    /// sheet had supported since FEAT3-UNDO.
    var mode: SpeakerNamingMode { currentName == nil ? .enroll : .rename }
}

/// A batch of segments the "New person..." label-only sheet is open for
/// (FEAT3-SEGMENT). Distinct from `NamingTarget`: this assigns a typed name to
/// specific lines through the overlay and enrolls no voiceprint, so it works for
/// `speaker_unknown` lines and people who were never diarized.
struct AssignNewTarget: Identifiable {
    let indices: [Int]
    var id: String { indices.map(String.init).joined(separator: ",") }
}

/// A transcript-row click, classified by held modifiers (FEAT3-SEGMENT multi-select):
/// plain seeks, Cmd toggles the segment in the selection, Shift extends the range.
enum SegmentClick { case plain, command, shift }

struct TranscriptTab: View {
    @ObservedObject var playback: AudioPlaybackController
    @EnvironmentObject private var libraryModel: LibraryWindowModel
    /// UX52: observed so a store rescan (the `revision` bump every in-place sidecar
    /// rewrite ends in) re-runs the reload task, which is how a finished
    /// re-transcribe reaches the pane the reader is already looking at. `SummaryTab`
    /// captures the store the same way and for the same reason: reaching through
    /// `libraryModel.meetingStore` reads the value without subscribing to it, so the
    /// bump would arrive and change nothing.
    @ObservedObject var store: MeetingStore
    let meeting: Meeting
    /// FEAT10: a time another tab asked us to reveal, set when the reader clicks
    /// an evidence chip in the Summary tab. Consumed (set back to nil) once the
    /// row has been scrolled to, so the same chip can be clicked again. A binding
    /// rather than a one-shot value because the tab switch and the transcript
    /// load race: the request outlives the switch and is honoured whenever the
    /// segments actually arrive. AUT02's deep link rides this same seam.
    @Binding var pendingSeek: Double?

    @State private var segments: [TranscriptSegment] = []
    @State private var language: String? = nil
    /// Reversible speaker-label overrides (FEAT3-UNDO). Resolved at display time so
    /// the diarization label in `<stem>.json` is never overwritten.
    @State private var speakerOverlay: SpeakerLabelStore.Overlay = .empty
    /// Flagged-moment offsets (FEAT8) from `<stem>.markers.json`, rendered as
    /// anchor chips in the transcript.
    @State private var markers: [Double] = []
    /// Diarization clusters with a voiceprint (FEAT3-ROSTER): the labels that can be
    /// enrolled. A label absent here gets per-line assignment, not cluster naming.
    @State private var voiceprintLabels: Set<String> = []
    /// The meeting's resolved people (FEAT3-SEGMENT), recomputed only when the
    /// segments or the overlay change. Deliberately NOT derived inside the list's
    /// `body`: that rebuilt it on every playback tick, which churned the context
    /// menu's content and stopped the "Assign to..." submenu from opening at all
    /// while audio was playing.
    @State private var cast: [CastMember] = []
    /// FEAT11: the cast classified into resolved names vs unresolved clusters, plus the
    /// roster-match count. Derived alongside `cast` in `reload` for the same reason it
    /// is: it reads the roster off disk, which has no business happening per render.
    @State private var voices: VoiceResolution.Outcome = .empty
    /// Pauses playback on a right-click so the context menu opens against a still
    /// list (see `installRightClickPause`).
    @State private var rightClickMonitor: Any? = nil
    @State private var loadedForStem: String? = nil
    /// Sidecar modification dates the loaded render was built from (UX52), so a
    /// store revision bump caused by another meeting's write costs four `stat`
    /// calls instead of re-parsing an 80-minute transcript.
    @State private var loadedFingerprint: [Date?]? = nil
    @State private var loading: Bool = true
    /// Segment whose edit sheet is open; nil when no sheet is showing.
    @State private var editingSegment: TranscriptSegment? = nil
    /// FEAT12: the vocabulary pair a just-saved line edit implies, held until the edit
    /// sheet has actually gone away. Presenting the second sheet in the same run-loop
    /// turn that dismisses the first is the well-known way to get neither, so the handoff
    /// happens in the edit sheet's `onDismiss`.
    @State private var pendingVocabularyOffer: VocabularyOffer? = nil
    /// FEAT12: the offer whose confirm sheet is open; nil when none is showing.
    @State private var vocabularyOffer: VocabularyOffer? = nil
    /// FEAT13: the line whose Clarify sheet is open; nil when none is showing.
    @State private var clarifyTarget: ClarifyTarget? = nil
    /// Raw speaker label being named (FEAT3-ROSTER); nil when the sheet is closed.
    @State private var namingTarget: NamingTarget? = nil
    /// Segments being assigned to a typed-in new person (FEAT3-SEGMENT); nil when closed.
    @State private var assignNewTarget: AssignNewTarget? = nil
    /// Drives the cast strip's roster rename (UX40), the one call here that is not a
    /// per-meeting overlay write. Owned the way `PeopleView` owns its own, since
    /// `RosterRename` needs a driver and the library model does not expose one.
    @State private var launcher = PipelineLauncher()

    var body: some View {
        VStack(spacing: 0) {
            if !voices.voices.isEmpty {
                // UX36: the cast strip is reading content, so it rides the shared
                // measure like the rows under it; its divider stays full-bleed
                // (chrome spans, content measures).
                // UX40: the chips route into the same three handlers the row menu uses,
                // so a rename or an un-name started from a chip is the same operation on
                // the same files as one started from a line.
                VoiceResolutionBar(
                    outcome: voices,
                    onName: { label in namingTarget = NamingTarget(label: label) },
                    onRename: { label, current in
                        namingTarget = NamingTarget(label: label, currentName: current)
                    },
                    onUnname: { label, current in undoNaming(label: label, name: current) },
                    onRenameEverywhere: { current in renameEverywhere(currentName: current) },
                    onAcceptSuggestion: { label, name in
                        acceptSuggestion(label: label, name: name)
                    }
                )
                .frame(maxWidth: SummaryLayout.readingMeasure, alignment: .leading)
                .padding(.horizontal, SummaryLayout.contentPadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                Divider().overlay(Color(MPColors.borderFaint))
            }
            content
            Divider()
            PlaybackBar(playback: playback)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        // UX52: two tasks, deliberately. The transcript reload has to re-run on a
        // store rescan as well as on a stem change; the audio load must not, since
        // re-attaching the player on every rescan would drop the play head under
        // whoever is listening.
        .task(id: meeting.stem) {
            if let audio = meeting.audioURL {
                playback.load(url: audio)
            }
        }
        .task(id: TranscriptReloadKey(stem: meeting.stem, revision: store.revision)) {
            await reload()
        }
        .sheet(item: $editingSegment, onDismiss: {
            // FEAT12: raise the vocabulary offer only once the editor is off screen.
            if let offer = pendingVocabularyOffer {
                pendingVocabularyOffer = nil
                vocabularyOffer = offer
            }
        }) { seg in
            // The sheet is a magnified copy of one row, so it reads that row's identity
            // (UX57) and its cast slot (UX58) rather than the raw diarization label,
            // which a reassignment never moves.
            let speaker = MeetingCast.rowSpeaker(
                for: seg, overlay: speakerOverlay, voiceprintLabels: voiceprintLabels
            )
            TranscriptLineEditor(
                segment: seg,
                speakerName: speaker.displayName,
                colorIndex: MeetingCast.colorIndex(for: speaker, in: cast),
                onSave: { newText in
                    saveCorrection(for: seg, newText: newText)
                    editingSegment = nil
                },
                onCancel: { editingSegment = nil }
            )
        }
        .sheet(item: $vocabularyOffer) { offer in
            VocabularyOfferSheet(
                offer: offer,
                onAdd: { heard, canonical, scope in
                    let message = addVocabularyTerm(heard: heard, canonical: canonical, workflow: scope)
                    if message == nil { vocabularyOffer = nil }
                    return message
                },
                // FEAT12: Cancel is the outcome of walking away, and it writes nothing.
                onCancel: { vocabularyOffer = nil }
            )
        }
        .sheet(item: $clarifyTarget) { target in
            ClarifySheet(
                target: target,
                onConfirm: { plan in applyClarify(plan) },
                // FEAT13: dismissing is walking away, and it writes neither file. The
                // Venusaur case is precisely this button.
                onCancel: { clarifyTarget = nil }
            )
        }
        .sheet(item: $namingTarget) { target in
            SpeakerNamingSheet(
                currentDisplay: target.currentName ?? TranscriptDisplay.displayName(for: target.label),
                mode: target.mode,
                initialName: target.currentName ?? "",
                onSave: { name in
                    if let old = target.currentName {
                        renameSpeaker(label: target.label, oldName: old, newName: name)
                    } else {
                        nameSpeaker(label: target.label, name: name)
                    }
                },
                onCancel: { namingTarget = nil }
            )
        }
        .sheet(item: $assignNewTarget) { target in
            SpeakerNamingSheet(
                currentDisplay: target.indices.count == 1 ? "this line" : "these \(target.indices.count) lines",
                mode: .assignNew,
                initialName: "",
                onSave: { name in
                    reassign(indices: target.indices, toLabel: name)
                    assignNewTarget = nil
                },
                onCancel: { assignNewTarget = nil }
            )
        }
        // Hold the transcript still while a sheet is open (FEAT3): naming or editing
        // a line while playback keeps scrolling the list out from under the cursor
        // is the friction that forced a manual pause every time.
        .onChange(of: editingSegment != nil || namingTarget != nil
                  || assignNewTarget != nil || vocabularyOffer != nil
                  || clarifyTarget != nil) { _, open in
            if open { playback.pause() }
        }
        .onAppear { installRightClickPause() }
        .onDisappear { removeRightClickPause() }
    }

    /// Pause playback the moment a right-click lands, so the context menu opens
    /// against a still list.
    ///
    /// The menu is built from live state, so every `playback.currentTime` tick
    /// re-evaluated it and tore down the open "Assign to..." submenu: it simply would
    /// not open while audio played. `rightMouseDown` is delivered before the menu is
    /// built, so pausing here means no ticks arrive while it is up. It also matches
    /// what the user was already doing by hand (stopping playback to name someone).
    /// The monitor only observes; it returns the event untouched so the menu still
    /// opens normally.
    private func installRightClickPause() {
        guard rightClickMonitor == nil else { return }
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { event in
            if playback.isPlaying { playback.pause() }
            return event
        }
    }

    private func removeRightClickPause() {
        if let monitor = rightClickMonitor {
            NSEvent.removeMonitor(monitor)
            rightClickMonitor = nil
        }
    }

    /// Enroll a speaker into the roster under `name` (FEAT3-ROSTER). Enrolls the
    /// voiceprint but leaves `<stem>.json` untouched, recording the name in the
    /// reversible overlay instead (FEAT3-UNDO); a reload then resolves the display.
    private func nameSpeaker(label: String, name: String) {
        namingTarget = nil
        Task {
            let result = await libraryModel.nameSpeaker(stem: meeting.stem, label: label, name: name)
            if case .success = result {
                await reload()
            }
        }
    }

    /// Accept the roster's near miss for a voice (FEAT14). Exactly `nameSpeaker`, with
    /// the sheet skipped because the name was already on the menu item the owner
    /// clicked: the suggestion is offered by name, so accepting it types nothing.
    ///
    /// Logged apart from a typed naming so the question this task exists to answer,
    /// whether surfacing near misses actually grows the enrolment corpus, is
    /// answerable from the event log rather than by guessing at roster sample counts.
    private func acceptSuggestion(label: String, name: String) {
        Log.event(category: "coordinator", action: "roster_suggestion_accepted", attributes: [
            "stem": meeting.stem, "label": label,
        ])
        nameSpeaker(label: label, name: name)
    }

    /// Undo a naming (FEAT3-UNDO): drop the overlay so the cluster reverts to its
    /// diarization label, and un-enroll the voiceprint so it no longer auto-names
    /// the voice in later meetings.
    private func undoNaming(label: String, name: String) {
        Task {
            _ = await libraryModel.undoSpeakerNaming(stem: meeting.stem, label: label, name: name)
            await reload()
        }
    }

    /// Rename an already-named speaker (FEAT3-UNDO): re-enroll under the new name,
    /// forget the old, and update the overlay.
    private func renameSpeaker(label: String, oldName: String, newName: String) {
        namingTarget = nil
        guard oldName != newName else { return }
        Task {
            _ = await libraryModel.renameSpeaker(
                stem: meeting.stem, label: label, oldName: oldName, newName: newName
            )
            await reload()
        }
    }

    /// Rename a roster-matched voice from the cast strip (UX40), through `RosterRename`:
    /// the same path Preferences ▸ Pipeline ▸ People and the Library's People rail take,
    /// so all three do the same thing to the same files.
    ///
    /// Global by nature, not by choice. A roster name is baked into `<stem>.json` by the
    /// pipeline's finalize, so there is no per-meeting overlay entry for a local rename
    /// to rewrite; the roster entry plus the carry across every meeting is the only edit
    /// that reaches it. The prompt says as much before it runs, and the menu item says it
    /// before the prompt.
    private func renameEverywhere(currentName: String) {
        guard let newName = RosterRename.prompt(currentName: currentName) else { return }
        RosterRename.run(from: currentName, to: newName, launcher: launcher) { result in
            switch result {
            case .success:
                // The carry rewrites this meeting's overlay too, so the reload is what
                // makes the chip and the rows follow.
                Task { await reload() }
            case .failure(let error):
                // A chip has no error slot, and a rename that changed nothing after a
                // modal prompt has to say so (the UX32 rail-row precedent).
                LibraryDialogs.reportRosterRenameProblem(PipelineLauncher.diagnostics(for: error))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading && loadedForStem != meeting.stem {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if segments.isEmpty {
            emptyState
        } else {
            TranscriptList(
                segments: segments,
                language: language,
                markers: markers,
                overlay: speakerOverlay,
                voiceprintLabels: voiceprintLabels,
                cast: cast,
                playback: playback,
                pendingSeek: pendingSeek,
                onSeekHandled: { pendingSeek = nil },
                onEdit: { seg in editingSegment = seg },
                onClarify: { seg in
                    let speaker = MeetingCast.rowSpeaker(
                        for: seg, overlay: speakerOverlay, voiceprintLabels: voiceprintLabels
                    )
                    clarifyTarget = ClarifyTarget(
                        segmentIndex: seg.index,
                        line: seg.text,
                        speakerName: speaker.displayName,
                        speakerColorIndex: MeetingCast.colorIndex(for: speaker, in: cast),
                        start: seg.start,
                        workflowName: meeting.workflowName
                    )
                },
                onName: { label in namingTarget = NamingTarget(label: label) },
                onRename: { label, current in
                    namingTarget = NamingTarget(label: label, currentName: current)
                },
                onUndoName: { label, current in undoNaming(label: label, name: current) },
                onReassign: { indices, label in reassign(indices: indices, toLabel: label) },
                onAssignNew: { indices in assignNewTarget = AssignNewTarget(indices: indices) },
                onResetReassignment: { indices in resetReassignment(indices: indices) }
            )
        }
    }

    /// Reassign a batch of segments to a speaker (FEAT3-SEGMENT). Local overlay write,
    /// then reload so the rows resolve the new labels; regenerate/republish are left to
    /// the detail menu rather than auto-fired.
    private func reassign(indices: [Int], toLabel label: String) {
        _ = libraryModel.reassignSegments(stem: meeting.stem, indices: indices, toLabel: label)
        Task { await reload() }
    }

    private func resetReassignment(indices: [Int]) {
        _ = libraryModel.resetSegmentReassignment(stem: meeting.stem, indices: indices)
        Task { await reload() }
    }

    /// Persists the edit and patches the in-memory segment so the row updates without a full reload.
    ///
    /// Returns nil on success, or a message the caller can render. The edit sheet
    /// discards it (it closes on save either way, and the failure is logged); FEAT13's
    /// Clarify sheet stays open and shows it.
    ///
    /// `offerVocabulary` is what keeps the two entry points from stacking sheets.
    /// Clarify passes false because it has *already* asked the vocabulary question, in
    /// its own picker, and the user answered it by choosing "Fix this line only";
    /// following that with an "Add to Vocabulary" offer would re-ask the question they
    /// just declined.
    @discardableResult
    private func saveCorrection(
        for segment: TranscriptSegment,
        newText: String,
        offerVocabulary: Bool = true
    ) -> String? {
        let edited = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        let pipelineOriginal = segment.text
        do {
            _ = try TranscriptCorrectionStore.upsert(
                segmentIndex: segment.index,
                pipelineOriginal: pipelineOriginal,
                edited: edited,
                stem: meeting.stem,
                in: meeting.recordingsDir
            )
        } catch {
            Log.event(category: "correction", action: "transcript_correction_failed",
                      attributes: [
                        "stem": meeting.stem,
                        "segment_index": segment.index,
                        "error": error.localizedDescription,
                      ])
            return error.localizedDescription
        }
        // SEC14: the event log is grepped and shared in diagnostics, so it carries lengths by
        // default, not the verbatim transcript sentences. The full text lands only under verbose.
        var attributes: [String: Any] = [
            "stem": meeting.stem,
            "segment_index": segment.index,
            "original_len": pipelineOriginal.count,
            "edited_len": edited.count,
        ]
        if UISettings.shared.verboseLogging {
            attributes["original_text"] = pipelineOriginal
            attributes["edited_text"] = edited
        }
        Log.event(category: "correction", action: "transcript_correction", attributes: attributes)
        // Patch in-memory list immediately. Reverting to original drops the override from the store; we apply the same resolution the loader does so the text flips back too.
        if let i = segments.firstIndex(where: { $0.index == segment.index }) {
            segments[i] = TranscriptSegment(
                index: segment.index,
                start: segment.start,
                end: segment.end,
                text: edited.isEmpty ? pipelineOriginal : edited,
                speakerID: segment.speakerID
            )
        }
        // FEAT12: the only moment both sides of a vocabulary pair are known. `make` is
        // pure, so this decides whether to *offer*, never whether to write; on a nil it
        // says nothing at all rather than nagging with an empty sheet.
        if offerVocabulary {
            pendingVocabularyOffer = VocabularyOffer.make(
                original: pipelineOriginal,
                edited: edited,
                workflowName: meeting.workflowName
            )
        }
        return nil
    }

    /// FEAT13: run a confirmed clarification, and nothing else.
    ///
    /// The two cases are one-to-one with the two destinations the sheet offered, which is
    /// the whole design: choosing "Fix this line only" writes the correction overlay and
    /// never `glossary.toml`, and choosing "Always fix this" writes the term and never
    /// the overlay. Writing both on the rule path was considered and rejected: an overlay
    /// laid over a term makes a rule that never matched look like it worked, so the owner
    /// would have no way to tell a live term from a dead one.
    ///
    /// Returns nil on success, or a message the sheet renders inline while staying open.
    private func applyClarify(_ plan: Clarify.Plan) -> String? {
        switch plan {
        case .correctLine(let index, let newText):
            guard let segment = segments.first(where: { $0.index == index }) else {
                return "That line is no longer on screen. Close this and try again."
            }
            if let message = saveCorrection(for: segment, newText: newText, offerVocabulary: false) {
                return message
            }
            clarifyTarget = nil
            return nil
        case .addTerm(let heard, let canonical, let workflow, let retranscribe):
            if let message = addVocabularyTerm(heard: heard, canonical: canonical, workflow: workflow) {
                return message
            }
            clarifyTarget = nil
            // No second confirmation: the tick box in the sheet was the ask, and the
            // sheet said what a rebuild does. Re-asking is the friction this task exists
            // to remove.
            if retranscribe { runRetranscribe() }
            return nil
        }
    }

    /// FEAT13: the rule path's optional rebuild. Reports through the shared dialog the
    /// detail header uses, so a carry that dropped an override says so in the same words
    /// wherever the re-transcribe was started from.
    ///
    /// Deliberately does **not** call `reload()` afterwards. `retranscribeMeeting`
    /// publishes the store revision itself on both outcomes (UX52), after the overlay
    /// carry, and this pane's `.task` is keyed on that revision, so the refresh is
    /// already owned. A `reload()` here would be the second signal beside the store's
    /// that `daemon/CLAUDE.md` warns against, and it would re-read the same bytes twice
    /// for one rebuild.
    private func runRetranscribe() {
        let title = meeting.displayTitle
        Task {
            let result = await libraryModel.retranscribeMeeting(stem: meeting.stem)
            await MainActor.run {
                LibraryDialogs.reportRetranscribe(meetingTitle: title, result: result)
            }
        }
    }

    /// FEAT12: the confirmed half of "Add to Vocabulary". Reached only from a confirm
    /// button (FEAT12's Add, or FEAT13's rule path), and it goes through
    /// `GlossaryStore.addTerm`, the same append the Preferences editor's rows ride, so
    /// there is no second writer of `glossary.toml`.
    ///
    /// The store is built here rather than held for the tab's lifetime so the document it
    /// merges into is read at confirm time, not at meeting-open time. It leaves one
    /// narrow race with a Preferences window sitting open on the Vocabulary group mid-keystroke,
    /// whose 500 ms debounce would then write its own document over this one; that costs
    /// the term, not the file, and closing the gap properly means shared ownership of the
    /// store, which is a bigger change than this leg is worth.
    ///
    /// Returns nil on success, or a message the sheet renders inline and stays open on:
    /// a vocabulary term the user confirmed and the pipeline never sees is exactly the
    /// silent failure FEAT11 existed to remove.
    private func addVocabularyTerm(heard: String, canonical: String, workflow: String?) -> String? {
        do {
            try GlossaryStore().addTerm(heard: heard, canonical: canonical, workflow: workflow)
        } catch {
            Log.event(category: "correction", action: "vocabulary_term_add_failed",
                      attributes: [
                        "stem": meeting.stem,
                        "error": error.localizedDescription,
                      ])
            return error.localizedDescription
        }
        // SEC14, the same split `transcript_correction` above makes: the term comes out of
        // a transcript line, so the log carries lengths and the scope by default and the
        // words themselves only under verbose.
        var attributes: [String: Any] = [
            "stem": meeting.stem,
            "scope": workflow == nil ? "global" : "workflow",
            "heard_len": heard.count,
            "canonical_len": canonical.count,
        ]
        if UISettings.shared.verboseLogging {
            attributes["heard"] = heard
            attributes["canonical"] = canonical
        }
        Log.event(category: "correction", action: "vocabulary_term_added", attributes: attributes)
        // Deliberately not closing a sheet here: this is the writer, and the two callers
        // own their own presentation. It closed `vocabularyOffer` when FEAT12 was the
        // only caller, which would have made FEAT13's rule path dismiss the wrong sheet.
        return nil
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 32))
                .foregroundStyle(Color(MPColors.fgSubtle))
            Text(meeting.status == .done
                 ? "No transcript on disk for this meeting."
                 : "Transcript appears once the pipeline finishes.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(Color(MPColors.fgMuted))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    /// Identity for the reload task (UX52): re-read when the stem changes OR when
    /// the store re-scanned, so a re-transcribe that rewrote this meeting's
    /// sidecars refreshes the open pane instead of waiting for the tab switch that
    /// used to be the only thing that revealed it. The fingerprint guard in
    /// `reload` makes a bump from an unrelated rescan a no-op. Same shape as
    /// `SummaryTab.SummaryReloadKey`, which is what already makes the summary pane
    /// refresh in place.
    private struct TranscriptReloadKey: Equatable {
        let stem: String
        let revision: Int
    }

    @MainActor
    private func reload() async {
        let stem = meeting.stem
        let dir = meeting.recordingsDir
        let fingerprint = TranscriptLoader.fingerprint(stem: stem, in: dir)
        // Already showing this stem's sidecars as they are on disk, so a revision
        // bump from an unrelated rescan changes nothing and must not re-parse.
        if loadedForStem == stem, loadedFingerprint == fingerprint { return }
        loading = true
        let owner = libraryModel.ownerLabel
        let loaded = await Task.detached(priority: .userInitiated) {
            (transcript: TranscriptLoader.load(stem: stem, in: dir),
             roster: RosterProfile.people().map(\.name))
        }.value
        let result = loaded.transcript
        guard meeting.stem == stem else { return }
        segments = result?.segments ?? []
        language = result?.language
        speakerOverlay = result?.speakerOverlay ?? .empty
        voiceprintLabels = result?.voiceprintLabels ?? []
        cast = MeetingCast.members(segments: segments, overlay: speakerOverlay)
        voices = VoiceResolution.derive(
            cast: cast,
            voiceprintLabels: voiceprintLabels,
            nearMisses: result?.nearMisses ?? [:],
            rosterNames: loaded.roster,
            userLabel: owner
        )
        // Small sidecar; a synchronous read on main is fine, like the corrections overlay.
        markers = MarkerFile.read(stem: stem, in: dir)?.markers.map(\.tSeconds) ?? []
        loadedForStem = stem
        loadedFingerprint = fingerprint
        loading = false
    }
}

// MARK: - List

private struct TranscriptList: View {
    let segments: [TranscriptSegment]
    let language: String?
    /// Flagged-moment offsets (FEAT8), anchored to their segments for chips.
    let markers: [Double]
    /// Reversible speaker-label overrides (FEAT3-UNDO), resolved per row for display.
    let overlay: SpeakerLabelStore.Overlay
    /// Diarization clusters that carry a voiceprint (FEAT3-ROSTER): only these offer
    /// cluster enrollment. Everything else gets per-line assignment.
    let voiceprintLabels: Set<String>
    /// The meeting's resolved people (FEAT3-SEGMENT). Passed in already computed and
    /// held in the host's state, NOT derived in `body`: rebuilding it on every
    /// `playback.currentTime` tick churned the context menu's content and tore down
    /// the open "Assign to..." submenu mid-interaction.
    let cast: [CastMember]
    @ObservedObject var playback: AudioPlaybackController
    /// FEAT10: a time to reveal, from an evidence chip in the Summary tab.
    let pendingSeek: Double?
    /// Called once the pending seek has been resolved to a row and scrolled to.
    let onSeekHandled: () -> Void
    /// Called on "Edit text" context-menu action; the host owns sheet presentation.
    let onEdit: (TranscriptSegment) -> Void
    /// Called on "Clarify a word…" (FEAT13); the host owns sheet presentation.
    let onClarify: (TranscriptSegment) -> Void
    /// Called on "Name this speaker" (FEAT3-ROSTER) with the label the row resolves to.
    /// That is the raw diarization label only when the line was never reassigned; on a
    /// reassigned line it is the label the line was moved *to* (UX57).
    let onName: (String) -> Void
    /// Called on "Rename…" (FEAT3-UNDO) with the row's label and its current name.
    let onRename: (String, String) -> Void
    /// Called on "Undo naming" (FEAT3-UNDO) with the row's label and its current name.
    let onUndoName: (String, String) -> Void
    /// Called on "Assign to <existing speaker>" (FEAT3-SEGMENT) with the target segment indices and the destination label.
    let onReassign: ([Int], String) -> Void
    /// Called on "New person…" (FEAT3-SEGMENT) with the target segment indices; the host opens the label-only naming sheet.
    let onAssignNew: ([Int]) -> Void
    /// Called on "Reset to original label" (FEAT3-SEGMENT) with the target segment indices.
    let onResetReassignment: ([Int]) -> Void

    /// Index of the segment containing the playback head. Updated via `onChange` so the binary search runs at most once per tick.
    @State private var activeIndex: Int? = nil
    /// Multi-segment selection for reassignment (FEAT3-SEGMENT); layered on Cmd/Shift-click so a plain click still seeks.
    @State private var selection = SegmentSelection()
    /// FEAT10: the row a just-followed evidence chip pointed at, held briefly so
    /// the reader's eye can find it after the jump, then cleared.
    @State private var citedIndex: Int? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long the cited row stays highlighted after a chip jump.
    private static let citationFlashSeconds: UInt64 = 2

    var body: some View {
        let markerMap = TranscriptMarkerLayout.assign(markers: markers, to: segments)
        let order = segments.map(\.index)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if let lang = language {
                        Text("Language: \(lang)")
                            .font(.caption)
                            .foregroundStyle(Color(MPColors.fgSubtle))
                            .padding(.top, 12)
                    }
                    // Discoverability caption (DSN22 #10): the rows are clickable to
                    // edit or seek, which is not otherwise obvious.
                    Text("Click a line to edit or seek.")
                        .font(.mpTextXS)
                        .foregroundStyle(Color(MPColors.fgSubtle))
                        .padding(.top, language == nil ? 12 : 2)
                        .padding(.bottom, 4)
                    ForEach(segments) { seg in
                        // UX57: one identity read per row. The name it shows, the items
                        // its menu offers, and the label those items write to all come
                        // from this single value, so a reassigned line can no longer act
                        // on the cluster it was moved away from. UX58 keyed the row's
                        // colour on the same value, which is why it is bound here rather
                        // than passed inline: the dot, the name, and the menu are one
                        // answer to "who is this line", not three.
                        let speaker = MeetingCast.rowSpeaker(
                            for: seg,
                            overlay: overlay,
                            voiceprintLabels: voiceprintLabels
                        )
                        if let times = markerMap[seg.index] {
                            MarkerChipsRow(times: times, onSeek: { playback.playFrom($0) })
                        }
                        TranscriptRow(
                            segment: seg,
                            speaker: speaker,
                            colorIndex: MeetingCast.colorIndex(for: speaker, in: cast),
                            isActive: seg.index == activeIndex,
                            isSelected: selection.contains(seg.index),
                            isCited: seg.index == citedIndex,
                            assignTargets: MeetingCast.assignTargets(
                                for: seg, cast: cast, overlay: overlay
                            ),
                            isReassigned: overlay.segments[seg.index] != nil,
                            onSelect: { kind in
                                switch kind {
                                case .plain:
                                    selection.plainClick(seg.index)
                                    playback.playFrom(seg.start)
                                case .command:
                                    selection.toggle(seg.index)
                                case .shift:
                                    selection.extendTo(seg.index, in: order)
                                }
                            },
                            onEdit: { onEdit(seg) },
                            onClarify: { onClarify(seg) },
                            onName: onName,
                            onRename: onRename,
                            onUndoName: onUndoName,
                            onReassignTo: { label in
                                onReassign(selection.targets(for: seg.index), label)
                                selection.clear()
                            },
                            onAssignNew: {
                                onAssignNew(selection.targets(for: seg.index))
                                selection.clear()
                            },
                            onResetSegment: {
                                onResetReassignment(selection.targets(for: seg.index))
                                selection.clear()
                            }
                        )
                        .id(seg.index)
                    }
                }
                .padding(.bottom, 12)
                // UX36: the transcript is a document, so it reads on the same
                // measure as the summary, modifier for modifier. Before this it
                // filled the pane, which made its wrapped monologue turns the
                // longest lines in the app (~1024pt at the column cap) and left
                // the right edge jumping ~300pt between the two reading tabs.
                // The captions and rows above dropped their own horizontal 16s
                // so this stack's gutter is the only inset; the playback bar and
                // the empty state stay full-bleed (instrument and state, not
                // reading content).
                .frame(maxWidth: SummaryLayout.readingMeasure, alignment: .leading)
                .padding(.horizontal, SummaryLayout.contentPadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onChange(of: playback.currentTime) { _, t in
                let newIdx = TranscriptSegmentLookup.index(at: t, in: segments)
                if newIdx != activeIndex {
                    activeIndex = newIdx
                    // Follow the play head, but not while a multi-select is being built
                    // (FEAT3-SEGMENT): auto-scrolling the rows out from under the cursor
                    // is what made reassigning a batch fight the user.
                    if playback.isPlaying, selection.isEmpty, let idx = newIdx {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(idx, anchor: .center)
                        }
                    }
                }
            }
            // FEAT10: honour a citation jump both when the request arrives while
            // this tab is already up, and when the tab was only just switched to
            // (the request is set before this view exists, so `onAppear` is the
            // one that fires then).
            .onAppear { reveal(pendingSeek, proxy: proxy) }
            .onChange(of: pendingSeek) { _, t in reveal(t, proxy: proxy) }
        }
        .textSelection(.enabled)
    }

    /// FEAT10: scroll the row containing `time` into view and hold a highlight on
    /// it briefly. The time-to-row mapping is the same binary search the play head
    /// uses, so a chip lands exactly where playback would.
    private func reveal(_ time: Double?, proxy: ScrollViewProxy) {
        guard let time, !segments.isEmpty else { return }
        // The verifier snaps every stored anchor to a real segment start, so the
        // lookup effectively always hits; falling back to the first row keeps a
        // hand-edited summary from doing nothing at all.
        let position = TranscriptSegmentLookup.index(at: time, in: segments) ?? 0
        let id = segments[position].index
        if reduceMotion {
            proxy.scrollTo(id, anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
        citedIndex = id
        onSeekHandled()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.citationFlashSeconds * 1_000_000_000)
            if citedIndex == id { citedIndex = nil }
        }
    }
}

/// Inline flag chips (FEAT8) for the moments anchored to a transcript segment.
/// Each chip shows the moment's timestamp and seeks to it on click, reusing the
/// same `playFrom` path as a row tap.
private struct MarkerChipsRow: View {
    let times: [Double]
    let onSeek: (Double) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(times, id: \.self) { t in
                Button {
                    onSeek(t)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 9))
                        Text(TranscriptDisplay.timestamp(t))
                            .font(.caption.monospacedDigit())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.mpSignal.opacity(0.18)))
                    .foregroundStyle(Color.mpSignal)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Flagged moment at \(TranscriptDisplay.timestamp(t)). Click to play.")
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }
}

private struct TranscriptRow: View {
    let segment: TranscriptSegment
    /// Who this line belongs to *now*, resolved once through the speaker overlay
    /// (UX57): the name to show, the menu items this row licenses, and the label each
    /// of those items writes to. The row holds no second identity to read, which is the
    /// point: it used to render the overlay's answer and act on the raw diarization
    /// label, so a reassigned line offered to rename the person it had been moved off.
    let speaker: MeetingCast.RowSpeaker
    /// This speaker's slot in the meeting's cast (UX58), which is what the dot and the
    /// name are tinted from. Passed in already resolved, off the same `speaker` above,
    /// so the row cannot colour one person and name another; nil draws muted.
    let colorIndex: Int?
    let isActive: Bool
    /// Selected for a multi-segment reassignment (FEAT3-SEGMENT).
    let isSelected: Bool
    /// FEAT10: this is the row a just-followed evidence chip cited. Held for a
    /// couple of seconds after the jump so the reader can see where they landed.
    let isCited: Bool
    /// The other people in this meeting, for the "Assign to..." menu.
    let assignTargets: [CastMember]
    /// True when this segment carries a per-segment reassignment (offers "Reset").
    let isReassigned: Bool
    /// A modifier-classified click: plain seeks, Cmd toggles, Shift range-selects.
    let onSelect: (SegmentClick) -> Void
    let onEdit: () -> Void
    /// FEAT13: open the Clarify sheet for this line.
    let onClarify: () -> Void
    let onName: (String) -> Void
    let onRename: (String, String) -> Void
    let onUndoName: (String, String) -> Void
    /// Reassign the current selection (or just this segment) to an existing label.
    let onReassignTo: (String) -> Void
    /// Assign the current selection (or just this segment) to a typed-in new person.
    let onAssignNew: () -> Void
    /// Reset the current selection's (or this segment's) per-segment reassignment.
    let onResetSegment: () -> Void

    /// Reveals the per-line Edit pencil on hover so transcript correction is
    /// discoverable without the right-click menu (TECH-UX12).
    @State private var isHovered = false

    var body: some View {
        Button(action: { onSelect(Self.classifyClick()) }) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(TranscriptDisplay.color(atCastIndex: colorIndex))
                    .frame(width: 8, height: 8)
                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(speaker.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(TranscriptDisplay.color(atCastIndex: colorIndex))
                        Text(TranscriptDisplay.timestamp(segment.start))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color(MPColors.fgSubtle))
                    }
                    Text(segment.text)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            // Horizontal inset lives on the list's shared measure stack (UX36);
            // a row that padded itself again would start its text 16pt off the
            // summary's, re-opening the per-tab edge disagreement in miniature.
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive
                          ? Color.mpSignal.opacity(0.18)
                          // FEAT10: the citation landing is a lighter wash than
                          // the play-head fill, so the two never read as the
                          // same state when both happen to be on screen.
                          : (isCited ? Color.mpSignal.opacity(0.10) : Color.clear))
                    .padding(.horizontal, 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Selected-for-reassignment outline (FEAT3-SEGMENT), distinct from the
        // playback-active fill so both can show. Non-interactive so it never eats a click.
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.mpSignal.opacity(0.7) : .clear, lineWidth: 1.5)
                .padding(.horizontal, 8)
                .allowsHitTesting(false)
        )
        // Hover affordance lives in the empty space beside the speaker/timestamp
        // line, so it never overlaps wrapped body text. The overlay is a sibling
        // layer over the row button, so its tap goes to Edit, not to seek.
        .overlay(alignment: .topTrailing) {
            if isHovered {
                MPGhostIconButton(
                    systemImage: "pencil",
                    help: "Edit this line",
                    action: onEdit
                )
                .padding(.trailing, 10)
            }
        }
        .onHover { hovering in
            isHovered = hovering
            // Pointer cursor so the line reads as clickable (DSN22 #10). macOS 14
            // floor rules out `.pointerStyle`, so push/pop the AppKit cursor.
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .contextMenu {
            Button("Edit text…", action: onEdit)
            // FEAT13. The row's own menu, and not a menu over the selected text, because
            // there is no such menu to extend: SwiftUI's `.textSelection(.enabled)` is
            // backed by a `SelectionTextField` that refuses first responder, engages no
            // field editor, and answers nil to `validRequestor(forSendType: .string,…)`,
            // so nothing in this process can be handed the words under the pointer
            // (measured 2026-08-04, extending UX48's probe). The full reasoning, and the
            // pasteboard hack that was rejected, are in `docs/backlog/tasks/FEAT13.md`.
            Button("Clarify a word…", action: onClarify)
            speakerItems
            assignMenu
        }
    }

    /// The speaker items, rendered straight off the pure rule rather than re-deciding
    /// per case here (the `VoiceResolutionBar.menu` idiom), so what ships is exactly
    /// what `MeetingCast.rowSpeaker` says and the tests pin. Each action carries its own
    /// target label, which is what makes the old wrong-target write unreachable from
    /// here: there is no raw label in scope to hand a callback by mistake.
    @ViewBuilder
    private var speakerItems: some View {
        ForEach(speaker.actions, id: \.self) { action in
            switch action {
            case .name(let label):
                // FEAT3-ROSTER: only an anonymous voice with a voiceprint can be
                // enrolled. A voiceprint-less line (speaker_unknown, an unclustered id,
                // a per-segment "New person") uses the assign menu below instead, which
                // never touches the roster and so cannot fail on a missing embedding.
                Button("Name this speaker…") { onName(label) }
            case .rename(let label, let currentName):
                // FEAT3-UNDO: an in-app-named cluster is reversible.
                Button("Rename…") { onRename(label, currentName) }
            case .unname(let label, let currentName):
                Button("Undo naming", role: .destructive) { onUndoName(label, currentName) }
            }
        }
    }

    /// FEAT3-SEGMENT: assign this segment (or the whole multi-selection) to someone
    /// else in the meeting or to a typed-in new person, or reset a prior assignment.
    /// Label-only: no voiceprint is enrolled, so roster centroids are untouched, and a
    /// new name is written straight to the overlay. "New person..." is the path for
    /// someone diarization missed (a mid-meeting joiner with a line or two) or an
    /// unknown line that belongs to nobody already listed. The targets come from the
    /// resolved cast, so a person introduced by an earlier "New person" is selectable
    /// here rather than having to be retyped every time.
    @ViewBuilder
    private var assignMenu: some View {
        Divider()
        Menu("Assign to\u{2026}") {
            ForEach(assignTargets) { target in
                Button(target.displayName) { onReassignTo(target.assignKey) }
            }
            if !assignTargets.isEmpty { Divider() }
            Button("New person\u{2026}") { onAssignNew() }
        }
        if isReassigned {
            Button("Reset to original label") { onResetSegment() }
        }
    }

    /// The click kind from the current modifier flags (macOS): Cmd toggles the
    /// selection, Shift range-selects, a plain click seeks (and clears the selection).
    static func classifyClick() -> SegmentClick {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) { return .command }
        if mods.contains(.shift) { return .shift }
        return .plain
    }
}

/// Name-entry sheet for the three speaker-naming flows: enrolling a diarized voice
/// into the roster (FEAT3-ROSTER), renaming an already-named one (FEAT3-UNDO), and
/// assigning specific lines to a typed-in new person (FEAT3-SEGMENT). The copy is
/// mode-specific because the enroll flow persists a cross-meeting voiceprint and the
/// line-assign flow deliberately does not.
enum SpeakerNamingMode { case enroll, rename, assignNew }

private struct SpeakerNamingSheet: View {
    let currentDisplay: String
    let mode: SpeakerNamingMode
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String

    init(
        currentDisplay: String,
        mode: SpeakerNamingMode = .enroll,
        initialName: String = "",
        onSave: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.currentDisplay = currentDisplay
        self.mode = mode
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: initialName)
    }

    private var title: String {
        switch mode {
        case .enroll:    return "Name \(currentDisplay)"
        case .rename:    return "Rename \(currentDisplay)"
        case .assignNew: return "Assign \(currentDisplay) to a new person"
        }
    }

    private var explanation: String {
        switch mode {
        case .enroll, .rename:
            // FEAT3-UNDO name-time honesty: state plainly that this enrolls a
            // persistent voiceprint affecting future meetings, reversibly.
            return "Enrolls this voice into your roster, so this person is named automatically in future meetings. You can undo the naming or remove them from your roster later from the speaker's right-click menu; the original diarization label is kept either way."
        case .assignNew:
            // FEAT3-SEGMENT: label-only, so be honest that it does NOT learn the voice.
            return "Labels the selected lines in this meeting only. No voiceprint is learned, so this person is not recognised automatically in other meetings. Use it for someone diarization missed, or a line that belongs to nobody already listed. Reversible from the same menu."
        }
    }

    private var saveTitle: String {
        switch mode {
        case .enroll:    return "Save"
        case .rename:    return "Rename"
        case .assignNew: return "Assign"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            Text(explanation)
                .font(.caption)
                .foregroundStyle(Color(MPColors.fgMuted))
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(saveTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
    }
}

// MARK: - Line editor sheet

private struct TranscriptLineEditor: View {
    let segment: TranscriptSegment
    /// Who the line shows, and their slot in the meeting's cast: the same two values the
    /// row under this sheet renders (UX57 / UX58). It used to read `segment.speakerID`
    /// for both, so the header of a reassigned line named the cluster it had been moved
    /// off and wore that cluster's colour.
    let speakerName: String
    let colorIndex: Int?
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String

    init(
        segment: TranscriptSegment,
        speakerName: String,
        colorIndex: Int?,
        onSave: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.segment = segment
        self.speakerName = speakerName
        self.colorIndex = colorIndex
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: segment.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(speakerName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TranscriptDisplay.color(atCastIndex: colorIndex))
                Text(TranscriptDisplay.timestamp(segment.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color(MPColors.fgSubtle))
                Spacer()
            }
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3))
                )
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: { onSave(text) })
                    .keyboardShortcut(.defaultAction)
                    .disabled(text == segment.text)
            }
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 240)
    }
}

// MARK: - Vocabulary offer sheet (FEAT12)

/// The confirm moment for "Add to Vocabulary", raised after a transcript line is saved
/// and only when the word-diff named a pair.
///
/// It is a **pre-fill, not an auto-write**, and the shape says so: both sides are
/// editable because the diff that filled them is deliberately dumb, the scope starts on
/// the meeting's workflow but can be widened, and the only thing that reaches
/// `glossary.toml` is the Add button. Dismissing writes nothing.
///
/// The pair fields deliberately mirror the Preferences editor's row (heard on the left,
/// correct spelling on the right, an arrow between) so the two surfaces read as the same
/// list, which is the one the user will find the term in afterwards.
private struct VocabularyOfferSheet: View {
    let offer: VocabularyOffer
    /// Returns nil on success, or a message to show while staying open.
    let onAdd: (String, String, String?) -> String?
    let onCancel: () -> Void

    @State private var heard: String
    @State private var canonical: String
    @State private var scope: String?
    @State private var error: String?

    init(
        offer: VocabularyOffer,
        onAdd: @escaping (String, String, String?) -> String?,
        onCancel: @escaping () -> Void
    ) {
        self.offer = offer
        self.onAdd = onAdd
        self.onCancel = onCancel
        _heard = State(initialValue: offer.pair.heard)
        _canonical = State(initialValue: offer.pair.canonical)
        _scope = State(initialValue: offer.defaultScope)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add to Vocabulary")
                .font(.headline)
            Text("From the line you just fixed. Nothing is saved until you add it.")
                .font(.caption)
                .foregroundStyle(Color(MPColors.fgMuted))
            HStack(alignment: .center, spacing: 8) {
                TextField("as heard", text: $heard)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .accessibilityLabel("Term as heard")
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(Color(MPColors.fgMuted))
                    .accessibilityHidden(true)
                TextField("correct spelling", text: $canonical)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Correct spelling")
            }
            if let workflow = offer.defaultScope {
                Picker("Applies to", selection: $scope) {
                    Text(workflow).tag(String?.some(workflow))
                    Text("Every meeting").tag(String?.none)
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 320, alignment: .leading)
            } else {
                Text("Applies to every meeting.")
                    .font(.caption)
                    .foregroundStyle(Color(MPColors.fgMuted))
            }
            // The FEAT11 acceptance loop, said at the moment it matters: terms are applied
            // when a transcript is finalized, so this meeting keeps the text just typed
            // until it is rebuilt, and Re-transcribe is the one action that rebuilds it.
            Text("Applied when a transcript is finalized, so meetings from now on pick it up on their own. This one keeps the text you just edited; use Re-transcribe\u{2026} from its \u{2026} menu to rebuild it with the term.")
                .font(.caption)
                .foregroundStyle(Color(MPColors.fgMuted))
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                FailureNotice(failure: FailurePresentation(diagnostics: error, operation: .processing, title: "Couldn't save this correction"))
                    .font(.mpTextXS)
                    .foregroundStyle(.mpDanger)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isLive)
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 460)
    }

    /// Mirrors `GlossaryTerm.isLive`: a row the pipeline would actually read.
    private var isLive: Bool {
        !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !canonical.isEmpty
    }

    private func submit() {
        guard isLive else { return }
        error = onAdd(heard.trimmingCharacters(in: .whitespacesAndNewlines), canonical, scope)
    }
}

// MARK: - Playback bar

private struct PlaybackBar: View {
    @ObservedObject var playback: AudioPlaybackController
    /// Scrubber value while dragging; committed on release. Without this the slider fights the timer tick and jumps.
    @State private var dragValue: Double? = nil

    var body: some View {
        if let err = playback.loadError {
            Label(err, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(Color(MPColors.fgMuted))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 10) {
                Button {
                    playback.togglePlayPause()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .keyboardShortcut(.space, modifiers: [])
                .buttonStyle(.borderless)

                Text(TranscriptDisplay.timestamp(displayedTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color(MPColors.fgMuted))
                    .frame(width: 48, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { displayedTime },
                        set: { v in dragValue = v }
                    ),
                    in: 0...max(playback.duration, 0.001),
                    onEditingChanged: { editing in
                        if !editing, let v = dragValue {
                            playback.seek(to: v)
                            dragValue = nil
                        }
                    }
                )

                Text(TranscriptDisplay.timestamp(playback.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color(MPColors.fgMuted))
                    .frame(width: 48, alignment: .leading)

                PlaybackRateMenu(playback: playback)
            }
        }
    }

    private var displayedTime: Double {
        dragValue ?? playback.currentTime
    }
}
