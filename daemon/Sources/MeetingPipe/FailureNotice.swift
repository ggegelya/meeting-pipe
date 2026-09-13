import AppKit
import SwiftUI

enum FailureReport {
    static func copy(_ preview: String, to board: NSPasteboard = .general) {
        board.clearContents()
        board.setString(preview, forType: .string)
    }
}

struct FailureNotice: View {
    let failure: FailurePresentation
    var retryLabel = "Retry"
    var retry: (() -> Void)? = nil
    var settings: (() -> Void)? = nil
    var downloadModel: (() -> Void)? = nil
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

    @ViewBuilder
    private var actions: some View {
        if let url = failure.billingURL {
            Button("Open billing") { NSWorkspace.shared.open(url) }
        }
        if failure.metadata.cause == .modelMissing, !failure.isSearchModelMissing, let downloadModel {
            Button(downloadRequested ? "Downloading…" : "Download model") {
                downloadRequested = true
                downloadModel()
            }.disabled(downloadRequested)
        } else if let label = failure.settingsLabel, let settings {
            Button(label, action: settings)
        }
        if let retry { Button(retryLabel, action: retry) }
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
                    .font(.mpTextXS).foregroundStyle(.secondary)
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 460),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingController(rootView: FailureDetailsView(failure: failure) {
            NSApp.stopModal()
            window.orderOut(nil)
        })
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(NSSize(width: 580, height: 460))
        window.title = "Failure details"
        window.center()
        NSApp.runModal(for: window)
    }
}
