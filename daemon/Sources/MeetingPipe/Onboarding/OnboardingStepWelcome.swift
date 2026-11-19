import SwiftUI

/// STOR6 item 3: the welcome step's copy, built from the same predicates the Permissions pane's
/// callout uses (`PrivacyReach`) and from where the library actually is (`CloudSyncDetector`).
/// It used to promise "Meeting notes that never leave your Mac" while the default engine sent
/// every transcript to Anthropic and the default library sat in iCloud-synced `~/Documents`.
enum WelcomeCopy {
    static let title = "Meeting notes from your calls"

    static func body(
        configuredBackend: String,
        regulatedMode: Bool,
        sinks: [WorkflowSink],
        libraryPath: String,
        syncedBy provider: String?
    ) -> String {
        let library: String
        if let provider {
            library = "Recordings are kept in \(libraryPath), which \(provider) syncs, so they are uploaded there as well."
        } else {
            library = "Recordings are kept in \(libraryPath) on this Mac."
        }
        return [
            "MeetingPipe notices your calls, records and transcribes them on this Mac, and writes a summary.",
            PrivacyReach.summarizationSentence(configuredBackend: configuredBackend, regulatedMode: regulatedMode),
            PrivacyReach.publishSentence(regulatedMode: regulatedMode, workflowSinks: sinks),
            library,
        ].joined(separator: " ")
    }
}

/// UX83: the Welcome step's "What should transcripts call you?" field. Prefilled, never
/// silently defaulted: the account name may be a nickname or "admin", and it ends up in
/// published summaries, so it is shown for the owner to confirm and saved only on Continue.
enum OwnerNameDraft {
    /// The saved name when there is one, else the Mac account's full name.
    static func initial(saved: String, accountName: String) -> String {
        let trimmed = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? accountName.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
    }

    /// What Continue writes to `summarization.user_label`, or nil to write nothing: the
    /// field left as the saved name, or cleared (blank keeps "You", which is a fine answer).
    static func toSave(draft: String, saved: String) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != saved.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return trimmed
    }
}

/// Step 1 (TECH-UX1): welcome, and what happens to a meeting under the current settings.
struct OnboardingStepWelcome: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var workflows: WorkflowStore
    /// UX83: held by `OnboardingRootView`, saved there on Continue.
    @Binding var ownerName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer(minLength: 0)
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color(MPColors.signal600))
            Text(WelcomeCopy.title)
                .font(.mpText2XL.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(bodyText)
                .font(.callout)
                .foregroundStyle(Color(MPColors.fgMuted))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("What should transcripts call you?")
                    .font(.callout.weight(.semibold))
                TextField("Your name", text: $ownerName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Text("Your own voice is labelled with this in transcripts and summaries. Leave it blank and it reads \"You\". You can change it later in Preferences \u{25B8} Pipeline.")
                    .font(.mpTextXS)
                    .foregroundStyle(Color(MPColors.fgSubtle))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bodyText: String {
        let path = store.outputDirPath
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return WelcomeCopy.body(
            configuredBackend: store.summarizationBackend,
            regulatedMode: store.regulatedMode,
            sinks: workflows.workflows.flatMap { $0.effectiveSinks },
            libraryPath: path,
            syncedBy: CloudSyncDetector.detect(path: url)?.name
        )
    }
}
