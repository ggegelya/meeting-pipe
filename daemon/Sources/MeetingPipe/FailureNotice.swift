import AppKit
import SwiftUI

enum FailureReport {
    static func copy(_ preview: String, to board: NSPasteboard = .general) {
        board.clearContents()
        board.setString(preview, forType: .string)
    }
}

/// What a `FailureNotice` offers before Details, in order (PIPE25). Pure, so the order is pinned
/// by a test rather than by reading the view.
enum FailureNoticeAction: Equatable {
    case billing, downloadModel, settings, showRecording, reSummarizeLocal, retry

    struct Inputs {
        var cause: FailureMetadata.Cause
        var isSearchModelMissing = false
        var hasBilling = false
        var hasSettings = false
        var canDownloadModel = false
        var canShowRecording = false
        var canRetry = false
        var canReSummarizeLocal = false
        /// Whether the configured local model is on disk; a re-summarize before it is would fail.
        var localModelCached = true
        /// Whether the meeting still resolves to Apple Intelligence, where a plain retry ends on
        /// the same local fallback the lead button runs (PIPE25's shared `summarizeOnDevice`).
        var resolvesToApple = true
    }

    static func decide(_ i: Inputs) -> [FailureNoticeAction] {
        if i.cause == .unsupportedLanguage, i.canReSummarizeLocal {
            // PIPE25: lead with the fix. Download first when the model is not there yet, since the
            // re-summarize would fail on it (item 4's honest failure), and no plain Retry while
            // the meeting resolves to Apple Intelligence, since it would only repeat that button.
            var out: [FailureNoticeAction] = []
            if !i.localModelCached, i.canDownloadModel { out.append(.downloadModel) }
            out.append(.reSummarizeLocal)
            if i.canRetry, !i.resolvesToApple { out.append(.retry) }
            return out
        }
        var out: [FailureNoticeAction] = []
        if i.hasBilling { out.append(.billing) }
        if i.cause == .modelMissing, !i.isSearchModelMissing, i.canDownloadModel {
            out.append(.downloadModel)
        } else if i.hasSettings {
            out.append(.settings)
        }
        if i.canShowRecording { out.append(.showRecording) }
        if i.canRetry { out.append(.retry) }
        return out
    }
}

struct FailureNotice: View {
    let failure: FailurePresentation
    var retryLabel = "Retry"
    var retry: (() -> Void)? = nil
    /// Show the held-back recording (SEC26); offered instead of `retry` on a held meeting.
    var showRecording: (() -> Void)? = nil
    var settings: (() -> Void)? = nil
    var downloadModel: (() -> Void)? = nil
    /// PIPE25: re-summarize on the local model, the fix for an Apple Intelligence language refusal.
    var reSummarizeLocal: (() -> Void)? = nil
    var localModelCached = true
    var resolvesToApple = true
    @State private var showDetails = false
    @State private var downloadRequested = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(failure.title, systemImage: "exclamationmark.triangle")
                .font(.mpTextSM.weight(.semibold))
                .foregroundStyle(Color(MPColors.fgMuted))
                .lineLimit(2)
            Text(failure.explanation)
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgMuted))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actions }.fixedSize()
                VStack(alignment: .leading, spacing: 8) { actions }
            }
            .controlSize(.regular)
            .foregroundStyle(Color(MPColors.fg))
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(MPColors.bgSunk), in: RoundedRectangle(cornerRadius: MPRadius.sm))
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $showDetails) {
            FailureDetailsView(failure: failure) { showDetails = false }
        }
        .onChange(of: failure) { _, _ in downloadRequested = false }
    }

    private var planned: [FailureNoticeAction] {
        FailureNoticeAction.decide(.init(
            cause: failure.metadata.cause, isSearchModelMissing: failure.isSearchModelMissing,
            hasBilling: failure.billingURL != nil,
            hasSettings: failure.settingsLabel != nil && settings != nil,
            canDownloadModel: downloadModel != nil, canShowRecording: showRecording != nil,
            canRetry: retry != nil, canReSummarizeLocal: reSummarizeLocal != nil,
            localModelCached: localModelCached, resolvesToApple: resolvesToApple
        ))
    }

    @ViewBuilder
    private var actions: some View {
        ForEach(planned, id: \.self) { action in
            switch action {
            case .billing:
                if let url = failure.billingURL { Button("Open billing") { NSWorkspace.shared.open(url) } }
            case .downloadModel:
                Button(downloadRequested ? "Downloading…" : "Download model") {
                    downloadRequested = true
                    downloadModel?()
                }.disabled(downloadRequested)
            case .settings:
                if let label = failure.settingsLabel, let settings { Button(label, action: settings) }
            case .showRecording:
                if let showRecording { Button("Show recording", action: showRecording) }
            case .reSummarizeLocal:
                if let reSummarizeLocal {
                    Button("Re-summarize with \(SummarizationEngine.local.qualified)", action: reSummarizeLocal)
                }
            case .retry:
                if let retry { Button(retryLabel, action: retry) }
            }
        }
        Button("Details…") { showDetails = true }
            .accessibilityLabel("Failure details")
            .accessibilityIdentifier("failure-details")
    }
}

struct FailureDetailsView: View {
    let failure: FailurePresentation
    var copyReport: (String) -> Void = { FailureReport.copy($0) }
    let close: () -> Void
    private var report: String {
        failure.report(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unavailable")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(failure.title).font(.headline).lineLimit(2)
            Text("Local diagnostics").font(.subheadline)
            FailureDiagnosticText(text: failure.diagnostics)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Local failure diagnostics")
            Text("Report preview").font(.subheadline)
            FailureDiagnosticText(text: report)
                .frame(height: 150)
                .accessibilityLabel("Report preview")
            HStack {
                Text("Only the preview is copied. Nothing is sent.")
                    .font(.mpTextXS).foregroundStyle(Color(MPColors.fgMuted))
                Spacer()
                Button("Copy report") { copyReport(report) }
                    .accessibilityIdentifier("copy-failure-report")
                Button("Close", action: close)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("close-failure-details")
            }
        }
        .padding(20)
        .frame(width: 580, height: 460)
    }
}

struct FailureDiagnosticText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let editor = NSTextView()
        editor.isEditable = false
        editor.isSelectable = true
        editor.isRichText = false
        editor.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        editor.textContainerInset = NSSize(width: 6, height: 6)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        scroll.documentView = editor
        editor.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView, editor.string != text else { return }
        editor.string = text
    }
}

enum FailureDialog {
    @MainActor
    static func alert(for failure: FailurePresentation) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = failure.title
        alert.informativeText = failure.explanation
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Details…")
        return alert
    }

    @MainActor
    static func show(_ failure: FailurePresentation) {
        let alert = alert(for: failure)
        if alert.runModal() == .alertSecondButtonReturn {
            showDetails(failure)
        }
    }

    @MainActor
    static func showDetails(_ failure: FailurePresentation) {
        let window = detailsWindow(for: failure)
        NSApp.runModal(for: window)
        // The window is ordered out, never closed, so nothing else lets go of the
        // hosting controller and the diagnostics text it holds (PERF27).
        window.contentViewController = nil
    }

    /// The Details window, built but not run. Its own function so a test can hold
    /// it weakly without entering a modal session (PERF27).
    ///
    /// The close closure captures the window weakly: the window owns the hosting
    /// controller, which owns the root view, which owns the closure, so a strong
    /// capture kept every Details window and its stderr tail alive for the life of
    /// the process. It orders out rather than calling `close()`, because a window
    /// built with this initializer is released on close, an extra release ARC does
    /// not expect.
    @MainActor
    static func detailsWindow(for failure: FailurePresentation) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 460),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingController(rootView: FailureDetailsView(failure: failure) { [weak window] in
            NSApp.stopModal()
            window?.orderOut(nil)
        })
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(NSSize(width: 580, height: 460))
        window.title = "Failure details"
        window.center()
        return window
    }
}
