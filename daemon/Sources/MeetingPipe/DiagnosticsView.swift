import AppKit
import SwiftUI

/// Read-only diagnostics viewer over the JSONL event logs (UX20). Ports the
/// `mp logs` since / category / action filters into the app so a detection
/// incident is triageable without a terminal. No mutation, no follow: a Reload
/// button re-reads on demand.
///
/// PERF13: the read happens off main in `DiagnosticsModel`, latest wins. It used to run on
/// main from every appear, filter change and Reload, which at the logs' size cap is seconds of
/// a frozen app, HUD Stop and global hotkeys included.
struct DiagnosticsView: View {
    @State private var since: SinceChoice = .hour1
    @State private var category: String = ""
    @State private var actionFilter: String = ""
    @StateObject private var model = DiagnosticsModel()

    private var events: [DiagnosticEvent] { model.result.events }

    enum SinceChoice: String, CaseIterable, Identifiable {
        case min15 = "15m", hour1 = "1h", hour6 = "6h", day1 = "1d", all = "All"
        var id: String { rawValue }
        var date: Date? {
            switch self {
            case .min15: return Date().addingTimeInterval(-15 * 60)
            case .hour1: return Date().addingTimeInterval(-3600)
            case .hour6: return Date().addingTimeInterval(-6 * 3600)
            case .day1: return Date().addingTimeInterval(-24 * 3600)
            case .all: return nil
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Color(MPColors.border))
            content
        }
        .background(Color(MPColors.bg))
        .onAppear(perform: reload)
    }

    private var toolbar: some View {
        HStack(spacing: MPSpace.s3) {
            Picker("", selection: $since) {
                ForEach(SinceChoice.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: since) { _, _ in reload() }

            Picker("", selection: $category) {
                Text("All categories").tag("")
                ForEach(DiagnosticsLog.categories, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 150)
            .onChange(of: category) { _, _ in reload() }

            TextField("action", text: $actionFilter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .onSubmit(reload)

            Spacer()

            if model.isLoading {
                ProgressView().controlSize(.small)
            }
            Text("\(events.count) event\(events.count == 1 ? "" : "s")")
                .font(.mpTextSM)
                .foregroundStyle(Color(MPColors.fgSubtle))
            // PERF13: a torn line is counted, so a lost row is visible rather than silent.
            if model.result.skipped > 0 {
                let n = model.result.skipped
                Text("\(n) unreadable line\(n == 1 ? "" : "s") skipped")
                    .font(.mpTextSM)
                    .foregroundStyle(Color.mpWarning)
                    .help("Lines in the event logs that are not complete JSON, usually two writes that collided. They are left out of the list.")
            }

            Button("Reload", action: reload)
            Button("Logs Folder") { NSWorkspace.shared.open(Log.logsDir) }
        }
        .padding(MPSpace.s3)
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if events.isEmpty {
            VStack(spacing: MPSpace.s2) {
                Spacer()
                Text("No events match these filters.")
                    .font(.mpTextBase)
                    .foregroundStyle(Color(MPColors.fgSubtle))
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(events) { row($0) }
                }
                .padding(.vertical, MPSpace.s1)
            }
        }
    }

    private func row(_ ev: DiagnosticEvent) -> some View {
        HStack(alignment: .top, spacing: MPSpace.s3) {
            Text(shortTime(ev))
                .foregroundStyle(Color(MPColors.fgSubtle))
                .frame(width: 128, alignment: .leading)
            Text(ev.category)
                .foregroundStyle(Color.mpSignal)
                .frame(width: 92, alignment: .leading)
            Text(ev.action)
                .foregroundStyle(Color(MPColors.fg))
                .frame(width: 168, alignment: .leading)
            Text(ev.detail)
                .foregroundStyle(Color(MPColors.fgMuted))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.mpTextSM.monospaced())
        .padding(.horizontal, MPSpace.s3)
        .padding(.vertical, MPSpace.s1)
    }

    private func shortTime(_ ev: DiagnosticEvent) -> String {
        guard let d = ev.date else { return ev.timestamp }
        return Self.rowFormatter.string(from: d)
    }

    private static let rowFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    private func reload() {
        let action = actionFilter.trimmingCharacters(in: .whitespaces)
        model.reload(DiagnosticsQuery(
            since: since.date,
            category: category.isEmpty ? nil : category,
            action: action.isEmpty ? nil : action
        ))
    }
}
