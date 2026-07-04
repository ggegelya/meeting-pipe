import SwiftUI

/// AI3: the Ask-AI projection. A question box over an engine-backed, cited answer
/// across the whole library. Retrieval + synthesis run on-device in the Python
/// `mp ask` subprocess (honouring the backend + egress clamp); each verified
/// `[stem]` citation links back to its source meeting, the same navigation Facts
/// rows use. Async by design (AI2 found live synthesis too slow), so a question
/// shows a spinner, then the answer. Rendered in the Library center column when
/// the `.ask` rail scope is active. Quiet register, no sparkle (PRODUCT.md).
struct AskView: View {
    @ObservedObject var model: LibraryWindowModel
    /// Navigate to a citation's source meeting (host: All Meetings + selected row).
    let onOpenMeeting: (String) -> Void

    @State private var question = ""
    @State private var asking = false
    @State private var answer: AskAnswer?
    @State private var errorText: String?
    @FocusState private var fieldFocused: Bool

    init(model: LibraryWindowModel, onOpenMeeting: @escaping (String) -> Void) {
        self.model = model
        self.onOpenMeeting = onOpenMeeting
    }

    var body: some View {
        VStack(spacing: 0) {
            askBar
            Divider()
            content
        }
        .onAppear { fieldFocused = true }
    }

    private var trimmedQuestion: String {
        question.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Ask bar

    private var askBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 13))
                .foregroundStyle(Color(MPColors.fgSubtle))
            TextField("Ask about your meetings…", text: $question)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color(MPColors.fg))
                .focused($fieldFocused)
                .onSubmit(ask)
                .disabled(asking)
            if asking {
                ProgressView().controlSize(.small)
            } else {
                Button("Ask", action: ask)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(trimmedQuestion.isEmpty ? Color(MPColors.fgSubtle) : Color.mpSignal)
                    .disabled(trimmedQuestion.isEmpty)
                    .accessibilityLabel("Ask")
            }
        }
        .padding(12)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if asking {
            working
        } else if let errorText {
            errorState(errorText)
        } else if let answer {
            if answer.empty {
                emptyCorpus
            } else {
                answerView(answer)
            }
        } else {
            prompt
        }
    }

    private var working: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Reading your meetings…")
                .font(.system(size: 12))
                .foregroundStyle(Color(MPColors.fgMuted))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func answerView(_ a: AskAnswer) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(a.answer)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(MPColors.fg))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if !a.citations.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(a.verified ? "Sources" : "Closest source")
                            .font(.system(size: 10, weight: .semibold))
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

                if let backend = a.backend {
                    Text(backendFooter(backend))
                        .font(.system(size: 10))
                        .foregroundStyle(Color(MPColors.fgSubtle))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    /// Quiet provenance line. On-device is the reassuring default; naming the
    /// cloud backend is honest when a non-regulated workflow used it.
    private func backendFooter(_ backend: String) -> String {
        switch backend {
        case "local", "apple_intelligence": return "Answered on-device"
        case "anthropic": return "Answered via Anthropic"
        default: return "Answered via \(backend)"
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(Color.mpWarning)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color(MPColors.fgMuted))
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
        Button { fillAndAsk(text) } label: {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color.mpSignal)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask: \(text)")
    }

    // MARK: - Actions

    private func fillAndAsk(_ text: String) {
        question = text
        ask()
    }

    private func ask() {
        let q = trimmedQuestion
        guard !q.isEmpty, !asking else { return }
        asking = true
        errorText = nil
        Task {
            let result = await model.askMeetings(question: q)
            await MainActor.run {
                asking = false
                switch result {
                case .success(let a):
                    if let e = a.error, !e.isEmpty {
                        errorText = e
                        answer = nil
                    } else {
                        answer = a
                        errorText = nil
                    }
                case .failure(let err):
                    errorText = err.localizedDescription
                    answer = nil
                }
            }
        }
    }
}
