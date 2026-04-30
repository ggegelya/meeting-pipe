import AppKit

/// Owns the NSStatusItem and its menu. Phase 0 just shows "Idle"; later phases
/// flip this to "Recording" and add Start/Stop entries.
final class StatusBarController {
    private let item: NSStatusItem
    weak var coordinator: Coordinator?

    init(item: NSStatusItem) {
        self.item = item
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "MeetingPipe")
            button.imagePosition = .imageLeft
        }
    }

    func setIdle() {
        item.button?.title = " Idle"
        rebuildMenu(state: .idle)
    }

    func setPrompting(_ source: AppSource) {
        item.button?.title = " Detected \(source.displayName)"
        rebuildMenu(state: .prompting(source: source))
    }

    func setRecording(file: URL) {
        item.button?.title = " Recording"
        rebuildMenu(state: .recording(file: file, source: nil, summaryMode: .auto))
    }

    func setStopping() {
        item.button?.title = " Stopping…"
        rebuildMenu(state: .idle)
    }

    func setHandoff() {
        item.button?.title = " Processing…"
        rebuildMenu(state: .idle)
    }

    private func rebuildMenu(state: AppState) {
        let menu = NSMenu()

        let header = NSMenuItem(title: stateLabel(state), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        switch state {
        case .idle:
            let start = NSMenuItem(title: "Start Recording", action: #selector(Coordinator.menuStart), keyEquivalent: "")
            start.target = coordinator
            menu.addItem(start)
        case .recording:
            let stop = NSMenuItem(title: "Stop Recording", action: #selector(Coordinator.menuStop), keyEquivalent: "")
            stop.target = coordinator
            menu.addItem(stop)
        default:
            break
        }

        menu.addItem(.separator())
        let openLogs = NSMenuItem(title: "Open Logs Folder", action: #selector(Coordinator.menuOpenLogs), keyEquivalent: "")
        openLogs.target = coordinator
        menu.addItem(openLogs)

        let openRecordings = NSMenuItem(title: "Open Recordings Folder", action: #selector(Coordinator.menuOpenRecordings), keyEquivalent: "")
        openRecordings.target = coordinator
        menu.addItem(openRecordings)

        menu.addItem(.separator())
        let prefs = NSMenuItem(title: "Preferences…", action: #selector(Coordinator.menuPreferences), keyEquivalent: ",")
        prefs.target = coordinator
        menu.addItem(prefs)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MeetingPipe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.menu = menu
    }

    private func stateLabel(_ s: AppState) -> String {
        switch s {
        case .idle: return "MeetingPipe: Idle"
        case .prompting(let src): return "MeetingPipe: Detected \(src.displayName)"
        case .suppressed(let src): return "MeetingPipe: Suppressed (\(src.displayName))"
        case .recording: return "MeetingPipe: Recording"
        case .stopping: return "MeetingPipe: Stopping…"
        case .handoff: return "MeetingPipe: Processing…"
        }
    }
}
