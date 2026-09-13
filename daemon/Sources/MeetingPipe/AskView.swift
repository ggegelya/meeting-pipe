import SwiftUI

/// Fixed measures for the Ask pane (UX38).
enum AskLayout {
    /// Ceiling on the centred invitation. Derived from what the invitation's own
    /// content wants to read at (a suggestion chip holding a question plus a
    /// title clipped at `AskPane.suggestionTitleLimit`, on one line), NOT from
    /// the list column's 400pt floor: `daemon/CLAUDE.md` has the worked example
    /// of the second mistake, where a card derived from the narrowest allowed
    /// window stayed frozen at that width on every window.
    static let invitationMeasure: CGFloat = 440
}

/// AI3: the Ask-AI projection. A question over an engine-backed, cited answer
/// across the whole library. Retrieval + synthesis run on-device in the Python
/// `mp ask` subprocess (honouring the backend + egress clamp); each verified
/// `[stem]` citation links back to its source meeting, the same navigation Facts
/// rows use. Async by design (AI2 found live synthesis too slow). Rendered in the
/// Library center column when the `.ask` rail scope is active.
///
/// UX37: a renderer, with no run state of its own. Everything that has to
/// outlive a rail switch (the question, the run in flight, this session's
/// answers) lives on `AskModel`, held by the Library root.
///
/// UX38 rewrote what that renders. Ask has a different job from every list rail
/// around it: Facts, People, Meeting time, and Digests are projections you read,
/// while Ask is a question you start, and rendering it as another sidebar-plus-
/// content page made an empty pane with a lonely text field that invited
/// nothing. So an empty Ask is a centred invitation, and the first question
/// **docks** the input to the top rather than shrinking it into a corner: a
/// corner hides the surface's primary affordance, while centre-then-top is the
/// move Spotlight-family muscle memory already has, and it keeps ask-again one
/// click away. Answers stack as a newest-first list rather than replacing each
/// other, since UX37 already keeps the session's history alive.
///
/// Every decision about *what* the pane shows lives in the pure `AskPane`; this
/// file is layout, motion, and the two callbacks. Motion is deliberately small
/// (one `durBase` ease-out on the dock, nothing else) and collapses to nothing
/// under Reduce Motion, per PRODUCT.md's quiet register.
struct AskView: View {
    @ObservedObject var model: LibraryWindowModel
    /// The surviving run state (UX37), owned by `LibraryRootView`.
    @ObservedObject var askModel: AskModel
    /// Captured explicitly so SwiftUI tracks it, the same reason `LibraryRootView`
    /// does: the suggested questions come off the newest meetings, so the
    /// invitation has to re-derive when the library gains one.
    @ObservedObject var meetingStore: MeetingStore
    /// Navigate to a citation's source meeting (host: All Meetings + selected row).
    let onOpenMeeting: (String) -> Void

    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: LibraryWindowModel, askModel: AskModel, onOpenMeeting: @escaping (String) -> Void) {
        self.model = model
        self.askModel = askModel
        self.meetingStore = model.meetingStore
        self.onOpenMeeting = onOpenMeeting
    }

    private var pane: AskPane {
        AskPane.derive(
            inFlight: askModel.inFlight,
            history: askModel.history,
            recentWorkflow: recentWorkflow,
            recentTitle: meetingStore.meetings.first?.displayTitle,
            meetingCount: meetingStore.meetings.count
        )
    }

    /// The newest tagged meeting's workflow. Bounded rather than a full scan:
    /// this runs on every store revision, and a workflow nobody has used in
    /// twenty meetings is not what "recently" means anyway.
    private var recentWorkflow: String? {
        meetingStore.meetings.prefix(20).compactMap(\.workflowName).first
    }

    /// AI12: which widths this backend on this Mac may honestly be asked for.
    ///
    /// Re-derived per render rather than stored, and normalized into the model
    /// on appear, because the backend is a Preferences setting that can change
    /// under a selection: this view is destroyed and rebuilt on every rail
    /// switch (the reason `AskModel` exists at all), so coming back to Ask is
    /// what re-resolves a width the machine can no longer take. The clamp in
    /// `mp.ask` stays the last line of defence for the window in between.
    private var widthOffer: AskContextWidth.Offer {
        AskContextWidth.offer(
            backendID: model.summarizationBackend,
            regulatedMode: model.regulatedMode,
            ramGB: LocalModelTier.physicalRamGB(),
            selectedID: askModel.contextWidthID
        )
    }

    var body: some View {
        let pane = self.pane
        let width = self.widthOffer
        // One VStack across both states, and the input keeps its slot in it, so
        // the dock is a move rather than a swap: the invitation's spacers and
        // header collapse around a control that stays the same view.
        return VStack(spacing: 0) {
            if !pane.isDocked {
                Spacer(minLength: 0)
                invitation(pane)
            }
            VStack(alignment: .leading, spacing: MPSpace.s2) {
                askBar(pane)
                widthControl(width)
            }
            .frame(maxWidth: pane.isDocked ? .infinity : AskLayout.invitationMeasure)
            .padding(MPSpace.s3)
            if !pane.isDocked {
                suggestions(pane)
                Spacer(minLength: 0)
            }
            if pane.isDocked {
                Divider()
                transcriptOfSession(pane)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: MPMotion.durBase), value: pane.layout)
        .onAppear {
            fieldFocused = true
            // AI12: pull the stored width back to one this backend and this Mac
            // can take, before anything can be asked at it. A deeplinked
            // question runs without the user touching the control, so this has
            // to happen ahead of the consume below rather than on first use.
            // Guarded because `@Published` fires on every set, equal or not.
            if askModel.contextWidthID != width.selection.id {
                askModel.contextWidthID = width.selection.id
            }
            // AUTO1: a meetingpipe://ask?q=... deeplink may have set the question
            // before this view mounted (the scope switch mounts it).
            consumePendingQuestion()
        }
        .onChange(of: model.pendingAskQuestion) { _, _ in consumePendingQuestion() }
        .onChange(of: askModel.isAsking) { _, running in
            // Clear the field once the run ends, not when it starts: while the
            // question is running it is the only place the question itself is
            // shown, and UX37 deliberately keeps the text through the run so a
            // rail switch cannot blank it. Once the answer (or the stop) is a
            // card, the same text sitting in the input is a leftover the user
            // has to delete before asking again, which is the opposite of what
            // docking the input to the top is for. A renderer decision, so
            // `AskModel`'s own contract is untouched.
            if !running { askModel.question = "" }
        }
    }

    /// AUTO1 + UX37: hand a deeplinked question to the model, which runs it and
    /// clears the pending question when that run *finishes*. Clearing it here on
    /// render is what used to lose the question on a mid-run scope switch.
    private func consumePendingQuestion() {
        askModel.acceptDeeplink(model.pendingAskQuestion) { model.pendingAskQuestion = nil }
    }

    // MARK: - Invitation

    private func invitation(_ pane: AskPane) -> some View {
        VStack(spacing: MPSpace.s2) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.mpText2XL)
                .foregroundStyle(Color(MPColors.fgSubtle))
            if let headline = pane.headline {
                Text(headline)
                    .font(.mpTextMD.weight(.medium))
                    .foregroundStyle(Color(MPColors.fg))
            }
            if let subhead = pane.subhead {
                Text(subhead)
                    .font(.mpTextSM)
                    .foregroundStyle(Color(MPColors.fgMuted))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, MPSpace.s4)
        .transition(.opacity)
    }

    /// Stacked rather than wrapped: every suggestion is a whole question, so a
    /// flow row would break them mid-sentence at any column width the list
    /// column actually gets.
    private func suggestions(_ pane: AskPane) -> some View {
        VStack(spacing: MPSpace.s2) {
            ForEach(pane.suggestions) { suggestion in
                Button(suggestion.text) { askModel.ask(suggestion.text) }
                    .buttonStyle(.mpGhost)
                    .accessibilityLabel("Ask: \(suggestion.text)")
            }
        }
        .padding(.horizontal, MPSpace.s4)
        .transition(.opacity)
    }

    // MARK: - Input

    private func askBar(_ pane: AskPane) -> some View {
        HStack(spacing: MPSpace.s2) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.mpTextBase)
                .foregroundStyle(Color(MPColors.fgSubtle))
            TextField(pane.fieldPlaceholder, text: $askModel.question)
                .textFieldStyle(.plain)
                .font(.mpTextBase)
                .foregroundStyle(Color(MPColors.fg))
                .focused($fieldFocused)
                .onSubmit { askModel.ask() }
                .disabled(pane.isRunning)
            if !pane.isRunning {
                Button("Ask") { askModel.ask() }
                    .buttonStyle(.plain)
                    .font(.mpTextSM.weight(.medium))
                    .foregroundStyle(askModel.trimmedQuestion.isEmpty
                                     ? Color(MPColors.fgSubtle)
                                     : Color.mpSignal)
                    .disabled(askModel.trimmedQuestion.isEmpty)
                    .accessibilityLabel("Ask")
            }
        }
        .padding(.horizontal, MPSpace.s3)
        .padding(.vertical, MPSpace.s2)
        .background(
            RoundedRectangle(cornerRadius: MPRadius.sm, style: .continuous)
                .fill(Color(MPColors.bgRaised))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MPRadius.sm, style: .continuous)
                .strokeBorder(Color(MPColors.borderStrong), lineWidth: 1)
        )
        .opacity(pane.isRunning ? 0.6 : 1)
    }

    // MARK: - How wide to read (AI12)

    /// The width dial and the two lines that make turning it honest, under the
    /// input rather than beside it: the cost has to be readable *before* the
    /// ask, and a caption tucked into the bar would be read as placeholder text.
    ///
    /// `SettingsSegmented` rather than a control of its own, for the reason
    /// `daemon/CLAUDE.md` gives about parallel one-offs, and it is the same
    /// named-position idiom DIAR3 uses for a knob whose raw number explains
    /// nothing. It is drawn only when there is a choice to make: on a Mac whose
    /// tier ceiling leaves one position, the reason line below is the whole
    /// truth and a one-segment control would be a control that does nothing.
    @ViewBuilder
    private func widthControl(_ offer: AskContextWidth.Offer) -> some View {
        VStack(alignment: .leading, spacing: MPSpace.s1) {
            if offer.showsPicker {
                SettingsSegmented(
                    selection: widthBinding(offer),
                    options: offer.positions.map { (value: $0.id, label: $0.label) }
                )
                .disabled(askModel.isAsking)
                .accessibilityLabel("How much of your library to read")
            }
            Text(offer.sublabel)
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgMuted))
                .fixedSize(horizontal: false, vertical: true)
            if let reason = offer.reason {
                Text(reason)
                    .font(.mpTextXS)
                    .foregroundStyle(Color(MPColors.fgSubtle))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Reads the *resolved* selection rather than the stored id, so the control
    /// can never be handed a tag that is not among its options (SwiftUI renders
    /// that as nothing selected), and writes the raw id, which the model
    /// re-resolves on the next appear.
    private func widthBinding(_ offer: AskContextWidth.Offer) -> Binding<String> {
        Binding(
            get: { offer.selection.id },
            set: { askModel.contextWidthID = $0 }
        )
    }

    // MARK: - The session

    /// The running state (when there is one) over the session's answers, newest
    /// first. The running block sits ABOVE the history rather than replacing it,
    /// so a new question never blanks the answer the user is still reading.
    private func transcriptOfSession(_ pane: AskPane) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MPSpace.s3) {
                if let running = pane.running {
                    runningCard(running, note: pane.inputNote)
                }
                ForEach(pane.entries) { entry in
                    entryCard(entry)
                }
            }
            // Cap the column, then left-align (UX36's rule): the answers are
            // prose, so they take the shared reading measure rather than
            // stretching across a wide window.
            .frame(maxWidth: SummaryLayout.readingMeasure, alignment: .leading)
            .padding(.horizontal, SummaryLayout.contentPadding)
            .padding(.vertical, MPSpace.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Running, with a way out (UX28's idiom: a long run is cancellable, and the
    /// cancel surfaces as a named outcome rather than a silent blank). The note
    /// under the line is UX37's one-at-a-time rule said out loud: a second ask
    /// is refused while this runs, and a refusal nothing on screen explains is
    /// indistinguishable from a dead button.
    private func runningCard(_ running: AskPane.Running, note: String?) -> some View {
        HStack(alignment: .top, spacing: MPSpace.s3) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: MPSpace.s1) {
                Text(running.line)
                    .font(.mpTextSM)
                    .foregroundStyle(Color(MPColors.fgMuted))
                if let note {
                    Text(note)
                        .font(.mpTextXS)
                        .foregroundStyle(Color(MPColors.fgSubtle))
                }
            }
            Spacer(minLength: MPSpace.s2)
            Button("Cancel") { askModel.cancel() }
                .buttonStyle(.mpGhost)
                .accessibilityLabel("Cancel this question")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MPSpace.s4)
        .mpSurface()
    }

    // MARK: - One answer

    private func entryCard(_ entry: AskEntry) -> some View {
        VStack(alignment: .leading, spacing: MPSpace.s3) {
            Text(entry.question)
                .font(.mpTextBase.weight(.medium))
                .foregroundStyle(Color(MPColors.fg))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            outcome(entry)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MPSpace.s4)
        .mpSurface()
    }

    @ViewBuilder
    private func outcome(_ entry: AskEntry) -> some View {
        if entry.wasCancelled {
            // UX37: a cancelled run is a named outcome, not a blank card, and
            // deliberately not an error. Nothing went wrong, the user stopped it.
            noteRow(icon: "stop.circle", tint: Color(MPColors.fgSubtle), text: "Stopped.")
        } else if let failure = entry.failure {
            FailureNotice(failure: failure,
                retry: askModel.inFlight == nil ? { _ = askModel.ask(entry.question) } : nil,
                settings: {
                    model.coordinator?.preferencesWindow?.show(initial:
                        [.memory, .modelMissing].contains(failure.metadata.cause) ? .pipeline : .integrations)
                }, downloadModel: { model.coordinator?.downloadLocalModelNow() })
        } else if let answer = entry.answer {
            if answer.empty {
                noteRow(icon: "tray", tint: Color(MPColors.fgSubtle),
                        text: "No meetings to search yet.")
            } else {
                answerBody(answer)
            }
        }
    }

    private func noteRow(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MPSpace.s2) {
            Image(systemName: icon)
                .font(.mpTextBase)
                .foregroundStyle(tint)
            Text(text)
                .font(.mpTextSM)
                .foregroundStyle(Color(MPColors.fgMuted))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func answerBody(_ a: AskAnswer) -> some View {
        VStack(alignment: .leading, spacing: MPSpace.s3) {
            // UX71: through the summary's own markdown rule, not a second one.
            // `Text` on a `String` renders markers literally, and the engines are
            // prompted for prose and return markdown, so an answer showing its
            // `**` is the normal case rather than a malformed reply. One `Text`
            // per line because the parse is inline-only: handed the whole answer
            // it would collapse a numbered list into a paragraph.
            VStack(alignment: .leading, spacing: MPSpace.s2) {
                ForEach(Array(SummaryMarkdown.lines(a.answer).enumerated()), id: \.offset) { _, line in
                    Text(SummaryMarkdown.inline(line))
                        .font(.mpTextBase)
                        .foregroundStyle(Color(MPColors.fg))
                        // UX48: a real mouse selection is how text leaves this
                        // app, so this survives the change of renderer.
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !a.citations.isEmpty {
                VStack(alignment: .leading, spacing: MPSpace.s2) {
                    Text(a.verified ? "Sources" : "Closest source")
                        .font(.mpTextXS.weight(.semibold))
                        .tracking(MPType.trackingCaps * MPType.textXS)
                        .textCase(.uppercase)
                        .foregroundStyle(Color(MPColors.fgMuted))
                    // Stacked for the same reason the suggestions are: a meeting
                    // title is a phrase, not a tag, and wrapping a row of them
                    // reads worse than a short column at any width this pane gets.
                    ForEach(a.citations) { c in
                        citationChip(c)
                    }
                }
            }

            if let footer = AskView.backendFooter(a.backend, substitutedFrom: a.substitutedFrom) {
                Text(footer)
                    .font(.mpTextXS)
                    .foregroundStyle(Color(MPColors.fgSubtle))
            }
        }
    }

    private func citationChip(_ c: AskCitation) -> some View {
        Button {
            onOpenMeeting(c.stem)
        } label: {
            HStack(spacing: MPSpace.s1) {
                Image(systemName: "arrow.up.forward.square")
                Text(c.title).lineLimit(1)
            }
            .foregroundStyle(Color.mpSignal)
        }
        .buttonStyle(.mpGhost)
        .help("Open meeting")
        .accessibilityLabel("Open meeting \(c.title)")
    }

    /// Quiet provenance line. On-device is the reassuring default; naming the
    /// cloud backend is honest when a non-regulated workflow used it.
    ///
    /// UX31: nil rather than a fallback for an engine this build cannot name.
    /// The old `default` interpolated the raw config id, so a Claude Code answer
    /// read "Answered via claude_cli"; a line the reader has to decode is worse
    /// than no line, and the provenance row in the detail header already hides
    /// itself for the same reason.
    ///
    /// UX64 gave it the substitution case. The derivation itself lives on
    /// `SummarizationEngine`, since the phrase needs two engines and this is a
    /// render site.
    static func backendFooter(_ backend: String?, substitutedFrom: String? = nil) -> String? {
        SummarizationEngine.answeredFooter(ran: backend, substitutedFrom: substitutedFrom)
    }
}
