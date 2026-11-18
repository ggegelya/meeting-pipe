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

/// Step 1 (TECH-UX1): welcome, and what happens to a meeting under the current settings.
struct OnboardingStepWelcome: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var workflows: WorkflowStore

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
