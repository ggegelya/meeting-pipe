import AppKit
import SwiftUI

/// SwiftUI Preferences window opened from the menu bar.
///
/// One window at a time — re-opening the menu item brings the existing
/// window to the front rather than stacking duplicates.
final class PreferencesWindow {
    private var window: NSWindow?
    private let store: ConfigStore

    init(store: ConfigStore) {
        self.store = store
    }

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = PreferencesView(store: store)
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = "MeetingPipe Preferences"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.setContentSize(NSSize(width: 480, height: 560))
        w.isReleasedWhenClosed = false
        w.center()
        // Capture close so we don't keep a dead window pointer around;
        // delegate target is held weakly.
        let delegate = PreferencesWindowDelegate { [weak self] in
            self?.window = nil
        }
        objc_setAssociatedObject(w, &Self.delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)
        w.delegate = delegate

        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static var delegateKey: UInt8 = 0
}

private final class PreferencesWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

private struct PreferencesView: View {
    @ObservedObject var store: ConfigStore

    @State private var newConsentBundleID: String = ""

    var body: some View {
        TabView {
            recordingTab
                .tabItem { Label("Recording", systemImage: "mic") }

            detectionTab
                .tabItem { Label("Detection", systemImage: "waveform") }

            modesTab
                .tabItem { Label("Modes", systemImage: "lock.shield") }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 520)
    }

    // MARK: Recording

    private var recordingTab: some View {
        Form {
            Section {
                LabeledContent("Output directory") {
                    HStack {
                        TextField("", text: $store.outputDirPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") { chooseOutputDir() }
                    }
                }
                LabeledContent("Sample rate") {
                    Picker("", selection: $store.sampleRate) {
                        Text("16 kHz (recommended)").tag(16000)
                        Text("24 kHz").tag(24000)
                        Text("48 kHz").tag(48000)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            Section("Auto-record without prompt") {
                if store.autoConsentApps.isEmpty {
                    Text("No bundle IDs added.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(store.autoConsentApps, id: \.self) { bid in
                        HStack {
                            Text(bid).font(.system(.body, design: .monospaced))
                            Spacer()
                            Button(role: .destructive) {
                                store.autoConsentApps.removeAll { $0 == bid }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                HStack {
                    TextField("us.zoom.xos", text: $newConsentBundleID)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        let trimmed = newConsentBundleID.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty,
                              !store.autoConsentApps.contains(trimmed) else { return }
                        store.autoConsentApps.append(trimmed)
                        newConsentBundleID = ""
                    }
                    .disabled(newConsentBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Detection

    private var detectionTab: some View {
        Form {
            Section("Debounce") {
                LabeledContent("Start (sec)") {
                    Slider(
                        value: $store.debounceStartSec,
                        in: 1...30,
                        step: 1
                    ) {
                        Text("Start debounce")
                    } minimumValueLabel: {
                        Text("1")
                    } maximumValueLabel: {
                        Text("30")
                    }
                    .frame(maxWidth: .infinity)
                    Text("\(Int(store.debounceStartSec))s").monospacedDigit().frame(width: 36, alignment: .trailing)
                }
                LabeledContent("End (sec)") {
                    Slider(value: $store.debounceEndSec, in: 1...30, step: 1)
                    Text("\(Int(store.debounceEndSec))s").monospacedDigit().frame(width: 36, alignment: .trailing)
                }
            }
            Section("Hotkey") {
                LabeledContent("Manual record") {
                    TextField("ctrl+option+m", text: $store.manualHotkey)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Format: 'ctrl+option+m', 'cmd+shift+r'. Restart MeetingPipe after changing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Prompt") {
                LabeledContent("Timeout (sec)") {
                    Slider(value: $store.promptTimeoutSec, in: 5...120, step: 5)
                    Text("\(Int(store.promptTimeoutSec))s").monospacedDigit().frame(width: 36, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Modes

    private var modesTab: some View {
        Form {
            Section("Regulated mode") {
                Toggle("Skip Notion publish (local Markdown only)", isOn: $store.regulatedMode)
                Text("When enabled, the pipeline writes summaries to disk only — no transcript or summary is uploaded to Notion. Use for client / regulated meetings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Tools") {
                Button("Open config in editor") {
                    NSWorkspace.shared.open(Config.defaultPath)
                }
                Button("Reveal config in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Config.defaultPath])
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Helpers

    private func chooseOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            store.outputDirPath = url.path
        }
    }
}
