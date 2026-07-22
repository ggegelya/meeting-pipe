import SwiftUI

/// Step 4 of 5 (UX22): choose where summaries publish. This closes the last
/// terminal / TOML dependency between install and first value: the Notion token
/// and database are set here, in the app, instead of hand-editing
/// `config.toml`. Every meeting is always saved on disk, so Notion is opt-in
/// and this step is skippable (filesystem is the zero-setup fallback).
///
/// "Verify connection" is read-only: it runs the same `GET /v1/databases/{id}`
/// probe as `mp doctor` to confirm the token is valid and the database is shared
/// with the integration. No page is created; a real publish stays the pipeline's
/// job.
struct OnboardingStepPublishTarget: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var secrets: SecretsStore
    @StateObject private var notionDBs = NotionDatabaseList()

    @State private var verifyState: VerifyState = .idle

    enum VerifyState: Equatable {
        case idle
        case checking
        case ok(String)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where summaries go")
                .font(.mpTextXL.weight(.semibold))
            Text("Every meeting is always saved on your Mac. To also publish summaries to Notion, add your integration token and pick a database. You can skip this and set it up later in Preferences.")
                .font(.callout)
                .foregroundStyle(Color(MPColors.fgMuted))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Notion integration token")
                    .font(.mpTextSM.weight(.medium))
                SecureField("ntn_…", text: $secrets.notionToken)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Database")
                    .font(.mpTextSM.weight(.medium))
                NotionDatabasePicker(
                    databaseID: $store.notionDatabaseId,
                    list: notionDBs,
                    disableFetch: store.regulatedMode
                )
            }

            HStack(spacing: 10) {
                Button("Verify connection") { verify() }
                    .disabled(!canVerify)
                verifyLabel
            }

            Text("Read-only: this checks your token and that the database is shared with the integration. Nothing is written to Notion.")
                .font(.caption)
                .foregroundStyle(Color(MPColors.fgSubtle))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Both halves present and not blocked by regulated mode (which forbids the
    /// daemon reaching Notion at all).
    private var canVerify: Bool {
        !secrets.notionToken.isEmpty
            && !store.notionDatabaseId.isEmpty
            && !store.regulatedMode
            && verifyState != .checking
    }

    @ViewBuilder
    private var verifyLabel: some View {
        switch verifyState {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.mpTextSM).foregroundStyle(Color(MPColors.fgMuted))
            }
        case .ok(let title):
            Label("Connected to \(title)", systemImage: "checkmark.circle.fill")
                .font(.mpTextSM)
                .foregroundStyle(.mpSuccess)
        case .failed(let err):
            Label(err, systemImage: "exclamationmark.triangle.fill")
                .font(.mpTextSM)
                .foregroundStyle(.mpDanger)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func verify() {
        let token = secrets.notionToken
        let dbId = store.notionDatabaseId
        verifyState = .checking
        Task {
            do {
                let title = try await NotionDatabaseList.verifyDatabase(token: token, databaseId: dbId)
                await MainActor.run { verifyState = .ok(title) }
            } catch {
                await MainActor.run { verifyState = .failed(error.localizedDescription) }
            }
        }
    }
}
