import SwiftUI

/// FEAT13: the confirm moment for a clarification, raised from a transcript line's
/// context menu.
///
/// The shape is the constraint. Both sides are typed by the user and the destination is
/// chosen explicitly, so **the only thing that reaches either file is one of the two
/// confirm buttons**; opening this sheet and dismissing it writes nothing at all, which
/// `ClarifyTests` pins on the bytes of both files rather than on this comment.
///
/// The destination picker is the safety-critical control, so it is a radio group and not
/// a menu: both blast radii are on screen at once, unopened, with the one that changes
/// only this meeting selected. The pair fields mirror the Preferences editor's row and
/// FEAT12's offer sheet (heard on the left, correct spelling on the right, an arrow
/// between), so the three surfaces read as the same list.
struct ClarifySheet: View {
    let target: ClarifyTarget
    /// Runs the plan. Returns nil on success, or a message to render inline while
    /// staying open: a clarification the user confirmed and the pipeline never sees is
    /// exactly the silent failure FEAT11 existed to remove.
    let onConfirm: (Clarify.Plan) -> String?
    let onCancel: () -> Void

    @State private var heard: String = ""
    @State private var intended: String = ""
    @State private var destination: Clarify.Destination = .thisLine
    @State private var scope: String?
    /// Off by default. Re-transcribing spends minutes of the Mac's time, and a sheet
    /// that starts a job the user did not ask for is the same class of surprise as a
    /// rule written without a confirm. The label states what it is for; ticking it is
    /// the ask.
    @State private var retranscribe: Bool = false
    @State private var error: String?
    @FocusState private var heardFocused: Bool

    init(
        target: ClarifyTarget,
        onConfirm: @escaping (Clarify.Plan) -> String?,
        onCancel: @escaping () -> Void
    ) {
        self.target = target
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _scope = State(initialValue: Clarify.defaultScope(workflowName: target.workflowName))
    }

    /// The plan the current fields imply, or nil when there is nothing honest to do.
    /// Drives the confirm button's enablement, so a disabled button and a refused write
    /// are the same rule rather than two.
    private var plan: Clarify.Plan? {
        Clarify.plan(
            segmentIndex: target.segmentIndex,
            line: target.line,
            heard: heard,
            intended: intended,
            destination: destination,
            scope: scope,
            retranscribe: retranscribe
        )
    }

    /// Why "Fix this line only" cannot act on a pair that is otherwise complete: the
    /// words are not in this line, so there is nothing to substitute. Without this the
    /// confirm button is simply dead and says nothing, which is the same silent dead end
    /// UX30 and UX40 had to fix on the workflow row and the cast chip. It points at the
    /// other destination rather than just refusing, because wanting a global rule for a
    /// spelling that appears elsewhere is a perfectly good reason to be here.
    private var lineHint: String? {
        guard destination == .thisLine, plan == nil else { return nil }
        let left = VocabularyCandidate.trimPunctuation(heard)
        let right = intended.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty, !right.isEmpty, left != right else { return nil }
        return "Those words are not in this line as written. Check the spelling, or choose \"\(Clarify.Destination.everyMeeting.title)\" to add them to your Vocabulary anyway."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            line
            pairFields
            Picker("", selection: $destination) {
                ForEach(Clarify.Destination.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .accessibilityLabel("What this clarification changes")
            Text(destination.explanation)
                .font(.caption)
                .foregroundStyle(Color(MPColors.fgMuted))
                .fixedSize(horizontal: false, vertical: true)
            if destination == .everyMeeting {
                scopeControl
                Toggle("Re-transcribe this meeting afterwards", isOn: $retranscribe)
                    .font(.caption)
                Text("Rebuilds this meeting's transcript from its audio so the new term reaches it. Your speaker names and text edits are carried over. Leave it off and use Re-transcribe\u{2026} from the meeting's \u{2026} menu whenever you like.")
                    .font(.caption)
                    .foregroundStyle(Color(MPColors.fgMuted))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let lineHint {
                Text(lineHint)
                    .font(.mpTextXS)
                    .foregroundStyle(Color(MPColors.fgMuted))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error)
                    .font(.mpTextXS)
                    .foregroundStyle(.mpDanger)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(destination.confirmTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 500)
        .onAppear { heardFocused = true }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Clarify")
                .font(.headline)
            Text("Type what was misheard and what it should say. Nothing is saved until you choose one of the two below.")
                .font(.caption)
                .foregroundStyle(Color(MPColors.fgMuted))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The line being clarified, shown so the misheard words can be read straight off it
    /// rather than remembered. Selectable for the same reason every other reading surface
    /// is, and muted so it reads as context rather than as another field.
    @ViewBuilder
    private var line: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(TranscriptDisplay.displayName(for: target.speakerID))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TranscriptDisplay.color(for: target.speakerID))
                Text(TranscriptDisplay.timestamp(target.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color(MPColors.fgSubtle))
                Spacer(minLength: 0)
            }
            Text(target.line)
                .font(.callout)
                .foregroundStyle(Color(MPColors.fgMuted))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(Color(MPColors.bgSunk))
        )
    }

    @ViewBuilder
    private var pairFields: some View {
        HStack(alignment: .center, spacing: 8) {
            TextField("as heard", text: $heard)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .focused($heardFocused)
                .accessibilityLabel("Words as heard")
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(Color(MPColors.fgMuted))
                .accessibilityHidden(true)
            TextField("what it should say", text: $intended)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("What it should say")
                .onSubmit { submit() }
        }
    }

    @ViewBuilder
    private var scopeControl: some View {
        if let workflow = Clarify.defaultScope(workflowName: target.workflowName) {
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
    }

    private func submit() {
        guard let plan else { return }
        error = onConfirm(plan)
    }
}
