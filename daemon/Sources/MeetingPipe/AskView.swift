import SwiftUI

/// AI3: the Ask-AI projection. A question box over an engine-backed, cited answer
/// across the whole library. Retrieval + synthesis run on-device in the Python
/// `mp ask` subprocess (honouring the backend + egress clamp); each verified
/// `[stem]` citation links back to its source meeting, the same navigation Facts
/// rows use. Async by design (AI2 found live synthesis too slow), so a question
/// shows a spinner, then the answer. Rendered in the Library center column when
/// the `.ask` rail scope is active. Quiet register, no sparkle (PRODUCT.md).
///
/// UX37: a renderer, with no run state of its own. Everything that has to
/// outlive a rail switch (the question, the run in flight, this session's
/// answers) lives on `AskModel`, held by the Library root, so leaving Ask
/// mid-question and coming back finds the spinner still turning and the answer
/// landing in place.
struct AskView: View {
    @ObservedObject var model: LibraryWindowModel
    /// The surviving run state (UX37), owned by `LibraryRootView`.
    @ObservedObject var askModel: AskModel
    /// Navigate to a citation's source meeting (host: All Meetings + selected row).
    let onOpenMeeting: (String) -> Void

    @FocusState private var fieldFocused: Bool

    init(model: LibraryWindowModel, askModel: AskModel, onOpenMeeting: @escaping (String) -> Void) {
        self.model = model
        self.askModel = askModel
        self.onOpenMeeting = onOpenMeeting
    }

    var body: some View {
        VStack(spacing: 0) {
            askBar
            Divider()
            content
        }
        .onAppear {
            fieldFocused = true
            // AUTO1: a meetingpipe://ask?q=... deeplink may have set the question
            // before this view mounted (the scope switch mounts it).
            consumePendingQuestion()
        }
        .onChange(of: model.pendingAskQuestion) { _, _ in consumePendingQuestion() }
    }

    /// AUTO1 + UX37: hand a deeplinked question to the model, which runs it and
    /// clears the pending question when that run *finishes*. Clearing it here on
    /// render is what used to lose the question on a mid-run scope switch.
    private func consumePendingQuestion() {
        askModel.acceptDeeplink(model.pendingAskQuestion) { model.pendingAskQuestion = nil }
    }

    // MARK: - Ask bar

    private var askBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 13))
                .foregroundStyle(Color(MPColors.fgSubtle))
            TextField("Ask about your meetings…", text: $askModel.question)
                .textFieldStyle(.plain)
                .font(.mpTextBase)
                .foregroundStyle(Color(MPColors.fg))
                .focused($fieldFocused)
                .onSubmit { askModel.ask() }
                .disabled(askModel.isAsking)
            if askModel.isAsking {
                ProgressView().controlSize(.small)
            } else {
                Button("Ask") { askModel.ask() }
                    .buttonStyle(.plain)
                    .font(.mpTextSM.weight(.medium))
                    .foregroundStyle(askModel.trimmedQuestion.isEmpty ? Color(MPColors.fgSubtle) : Color.mpSignal)
                    .disabled(askModel.trimmedQuestion.isEmpty)
                    .accessibilityLabel("Ask")
            }
        }
        .padding(12)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if askModel.isAsking {
            working
        } else if let latest = askModel.latest {
            outcomeView(latest)
        } else {
            prompt
        }
    }

    /// The newest question's outcome. The rest of the session's history lives on
    /// the model; rendering it as a list is UX38's redesign, not this task's.
    @ViewBuilder
    private func outcomeView(_ entry: AskEntry) -> some View {
        if entry.wasCancelled {
            cancelledState(entry.question)
        } else if let message = entry.errorText {
            errorState(message)
        } else if let answer = entry.answer {
            if answer.empty {
                emptyCorpus
            } else {
                answerView(answer)
            }
        }
    }

    /// Running, with a way out (UX28's idiom: a long run is cancellable, and the
    /// cancel surfaces as a named outcome rather than a silent blank).
    private var working: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Reading your meetings…")
                .font(.mpTextSM)
                .foregroundStyle(Color(MPColors.fgMuted))
            Button("Cancel") { askModel.cancel() }
                .controlSize(.small)
                .fixedSize()
                .accessibilityLabel("Cancel this question")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func answerView(_ a: AskAnswer) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(a.answer)
                    .font(.mpTextBase)
                    .foregroundStyle(Color(MPColors.fg))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if !a.citations.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(a.verified ? "Sources" : "Closest source")
                            .font(.mpTextXS.weight(.semibold))
                            .tracking(0.08 * 10)
                            .textCase(.uppercase)
                            .foregroundStyle(Color(MPColors.fgMuted))
                        ForEach(a.citations) { c in
                            Button { onOpenMeeting(c.stem) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.up.forward.square")
                                        .font(.system(size: 11))
                                    Text(c.title).lineLimit(1)
                                }
                                .foregroundStyle(Color.mpSignal)
                            }
                            .buttonStyle(.plain)
                            .help("Open meeting")
                            .accessibilityLabel("Open meeting \(c.title)")
                        }
                    }
                }

                if let footer = AskView.backendFooter(a.backend) {
                    Text(footer)
                        .font(.mpTextXS)
                        .foregroundStyle(Color(MPColors.fgSubtle))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    /// Quiet provenance line. On-device is the reassuring default; naming the
    /// cloud backend is honest when a non-regulated workflow used it.
    ///
    /// UX31: nil rather than a fallback for an engine this build cannot name.
    /// The old `default` interpolated the raw config id, so a Claude Code answer
    /// read "Answered via claude_cli"; a line the reader has to decode is worse
    /// than no line, and the provenance row in the detail header already hides
    /// itself for the same reason.
    static func backendFooter(_ backend: String?) -> String? {
        SummarizationEngine.resolve(backend).map { "Answered \($0.runPhrase)" }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(Color.mpWarning)
            Text(message)
                .font(.mpTextSM)
                .foregroundStyle(Color(MPColors.fgMuted))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    /// UX37: a cancelled run is a named outcome, not a blank pane. It says which
    /// question was stopped so the field's text is not the only clue, and it is
    /// deliberately not an error: nothing went wrong, the user stopped it.
    private func cancelledState(_ question: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "stop.circle")
                .font(.mpText2XL)
                .foregroundStyle(Color(MPColors.fgSubtle))
            Text("Stopped.")
                .font(.mpTextSM)
                .foregroundStyle(Color(MPColors.fgMuted))
            Text(question)
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgSubtle))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var emptyCorpus: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(Color(MPColors.fgSubtle))
            Text("No meetings to search yet.")
                .foregroundStyle(Color(MPColors.fgMuted))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var prompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(Color(MPColors.fgSubtle))
            Text("Ask a question about your meetings.")
                .foregroundStyle(Color(MPColors.fgMuted))
            VStack(alignment: .leading, spacing: 4) {
                exampleRow("What did we decide about the budget?")
                exampleRow("What are my open action items?")
                exampleRow("What did we say about hiring?")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func exampleRow(_ text: String) -> some View {
        Button { askModel.ask(text) } label: {
            Text(text)
                .font(.mpTextSM)
                .foregroundStyle(Color.mpSignal)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask: \(text)")
    }
}
