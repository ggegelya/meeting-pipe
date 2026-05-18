import AppKit
import Combine
import SwiftUI

/// Menu-bar quick-find panel (TECH-A3). A small floating NSPanel that
/// pops over whatever the user is doing, with a search field at the
/// top and a ranked match list below. Enter opens the meeting in the
/// Library window; Esc dismisses; arrow keys move the selection.
///
/// All public methods touch AppKit so they must be called on the main
/// thread; the @objc menu actions in `Coordinator` already satisfy
/// that, so explicit `@MainActor` annotation is omitted to keep the
/// type usable from the non-isolated `Coordinator`.
final class QuickFindWindow {

    private let model: QuickFindModel
    private var panel: NSPanel?

    init(meetingStore: MeetingStore, onSelect: @escaping (Meeting) -> Void) {
        let placeholder = QuickFindModel(
            meetingStore: meetingStore,
            onSelect: onSelect,
            onDismiss: {}
        )
        self.model = placeholder
        // Wire the dismiss callback after self is initialized so the
        // closure can capture this instance without an init-order
        // crash. The placeholder dismiss is never invoked.
        placeholder.onDismiss = { [weak self] in self?.hide() }
    }

    func show() {
        if let p = panel {
            p.center()
            p.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            model.refresh()
            return
        }
        let view = QuickFindView(model: model)
        let host = NSHostingController(rootView: view)
        let p = NSPanel(contentViewController: host)
        p.styleMask = [.titled, .closable, .fullSizeContentView, .hudWindow]
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .floating
        p.becomesKeyOnlyIfNeeded = false
        p.hidesOnDeactivate = true
        p.isMovableByWindowBackground = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.setContentSize(NSSize(width: 520, height: 360))
        p.center()
        self.panel = p
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.refresh()
    }

    func hide() {
        panel?.orderOut(nil)
    }
}

/// Backing model for the SwiftUI surface. Holds the query, the current
/// matches, and the selected row's index; bound to `MeetingStore` so the
/// match list re-ranks when the library scans new files. Lives across
/// open/close cycles of the window so a re-open starts with a clean
/// query. Mutations land on the main queue via `MeetingStore`'s own
/// publish path and the SwiftUI bindings on the panel.
final class QuickFindModel: ObservableObject {

    @Published var query: String = "" {
        didSet { recomputeMatches() }
    }
    @Published private(set) var matches: [QuickFindRanker.Match] = []
    /// Index into `matches`. Clamped on every recompute so a result
    /// reshuffle doesn't strand the highlight off the end of the list.
    @Published var selectedIndex: Int = 0

    private let meetingStore: MeetingStore
    private let onSelect: (Meeting) -> Void
    var onDismiss: () -> Void
    private var cancellables: Set<AnyCancellable> = []

    init(
        meetingStore: MeetingStore,
        onSelect: @escaping (Meeting) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.meetingStore = meetingStore
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        meetingStore.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.recomputeMatches() }
            .store(in: &cancellables)
    }

    /// Force the store to scan, then recompute. Called when the
    /// window opens so a stale list from yesterday doesn't show up.
    func refresh() {
        meetingStore.start()
        recomputeMatches()
    }

    func moveSelection(by delta: Int) {
        guard !matches.isEmpty else { return }
        let next = min(max(selectedIndex + delta, 0), matches.count - 1)
        selectedIndex = next
    }

    func selectCurrent() {
        guard let m = matches[safe: selectedIndex]?.meeting else { return }
        onSelect(m)
        onDismiss()
    }

    func cancel() {
        onDismiss()
    }

    private func recomputeMatches() {
        let m = QuickFindRanker.rank(
            query: query,
            in: meetingStore.meetings,
            limit: 50
        )
        self.matches = m
        if m.isEmpty {
            selectedIndex = 0
        } else if selectedIndex >= m.count {
            selectedIndex = m.count - 1
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}

// MARK: - SwiftUI view

struct QuickFindView: View {
    @ObservedObject var model: QuickFindModel
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider()
            results
        }
        .frame(width: 520, height: 360)
        .background(.regularMaterial)
        .onAppear { queryFocused = true }
        // Background key handler so arrows + enter + esc work even
        // when focus is in the search field (which captures most
        // keystrokes).
        .background(
            KeyCatcher(
                onDown: { model.moveSelection(by: 1) },
                onUp: { model.moveSelection(by: -1) },
                onReturn: { model.selectCurrent() },
                onEscape: { model.cancel() }
            )
        )
    }

    private var searchHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find a meeting…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($queryFocused)
                .onSubmit { model.selectCurrent() }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    @ViewBuilder
    private var results: some View {
        if model.matches.isEmpty {
            VStack {
                Spacer()
                Text(model.query.isEmpty
                     ? "Start typing to search the library."
                     : "No matches.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.matches.enumerated()), id: \.element.id) { idx, match in
                            QuickFindRow(
                                match: match,
                                isSelected: idx == model.selectedIndex
                            )
                            .id(idx)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selectedIndex = idx
                                model.selectCurrent()
                            }
                        }
                    }
                }
                .onChange(of: model.selectedIndex) { _, new in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct QuickFindRow: View {
    let match: QuickFindRanker.Match
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(match.meeting.displayTitle)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
            HStack(spacing: 6) {
                if let wf = match.meeting.workflowName, !wf.isEmpty {
                    Text(wf)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(QuickFindRow.dateFormatter.string(from: match.meeting.startedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(match.hitField)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected
            ? Color.accentColor.opacity(0.25)
            : Color.clear
        )
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

/// Invisible NSView that swallows arrow / return / escape so the
/// shared TextField can keep focus while the surrounding panel still
/// drives the list selection.
private struct KeyCatcher: NSViewRepresentable {
    let onDown: () -> Void
    let onUp: () -> Void
    let onReturn: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> KeyCatcherView {
        let v = KeyCatcherView()
        v.onDown = onDown
        v.onUp = onUp
        v.onReturn = onReturn
        v.onEscape = onEscape
        return v
    }

    func updateNSView(_ nsView: KeyCatcherView, context: Context) {
        nsView.onDown = onDown
        nsView.onUp = onUp
        nsView.onReturn = onReturn
        nsView.onEscape = onEscape
    }
}

private final class KeyCatcherView: NSView {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case 125: onDown?(); return true  // arrow down
        case 126: onUp?(); return true    // arrow up
        case 36:  onReturn?(); return true // return
        case 53:  onEscape?(); return true // escape
        default:  return super.performKeyEquivalent(with: event)
        }
    }
}
