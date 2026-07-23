import AppKit
import Combine
import SwiftUI

/// Menu-bar quick-find floating panel (TECH-A3; opened with Cmd+K since UX16). Enter opens the selected meeting, Esc dismisses, arrows move selection. Searches the same FTS5 index as the Library filter bar (UX16). UX25 adds the Ask handoff: `onAsk` sends the typed query to the Library's Ask rail, prefilled and running. Not annotated `@MainActor` so it remains usable from the non-isolated `Coordinator`, which already calls it on the main thread.
final class QuickFindWindow {

    private let model: QuickFindModel
    private var panel: NSPanel?

    init(
        meetingStore: MeetingStore,
        ftsMatches: @escaping (String) -> Set<String>? = { _ in nil },
        searchHealth: @escaping () -> SearchIndexer.Health = { .ready },
        onSelect: @escaping (Meeting) -> Void,
        onAsk: @escaping (String) -> Void = { _ in }
    ) {
        let placeholder = QuickFindModel(
            meetingStore: meetingStore,
            ftsMatches: ftsMatches,
            searchHealth: searchHealth,
            onSelect: onSelect,
            onAsk: onAsk,
            onDismiss: {}
        )
        self.model = placeholder
        // Wire dismiss after init so the closure can capture self without an init-order crash; the placeholder dismiss is never invoked.
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
        let host = NSHostingController(rootView: MPControlAccent(view))
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

/// Backing model for the quick-find panel. Bound to `MeetingStore` so the list re-ranks on library changes. Lives across open/close cycles; mutations land on the main queue via `MeetingStore`'s publish path.
final class QuickFindModel: ObservableObject {

    @Published var query: String = "" {
        didSet { recomputeMatches() }
    }
    /// UX25: the ranked meetings plus the Ask handoff row, in display order. The panel drives
    /// selection over this list rather than over the matches, so the Ask row is a first-class
    /// keyboard target instead of a click-only footer.
    @Published private(set) var items: [QuickFindItem] = []
    /// Whether any meeting matched, so the panel can say "No meetings matched." above an
    /// Ask-only list. Stored rather than derived so the view doesn't rescan on every render.
    @Published private(set) var hasMeetingMatches: Bool = false
    /// Clamped on every recompute so a result reshuffle doesn't strand the highlight off the end of the list.
    @Published var selectedIndex: Int = 0
    /// UX23: the search index's health, refreshed on each recompute so the panel can show a one-line
    /// hint when full-text search is still building or has degraded. Read at recompute time (rather
    /// than observed) because the panel is transient and re-samples on every keystroke.
    @Published private(set) var indexHealth: SearchIndexer.Health = .ready

    private let meetingStore: MeetingStore
    /// UX16: FTS candidate stems for the query, so Quick Find searches full transcripts too. Nil
    /// (empty query / no index) means field-only ranking, unchanged.
    private let ftsMatches: (String) -> Set<String>?
    private let searchHealth: () -> SearchIndexer.Health
    private let onSelect: (Meeting) -> Void
    /// UX25: hand the query to the Library's Ask rail, prefilled and running.
    private let onAsk: (String) -> Void
    var onDismiss: () -> Void
    private var cancellables: Set<AnyCancellable> = []

    init(
        meetingStore: MeetingStore,
        ftsMatches: @escaping (String) -> Set<String>? = { _ in nil },
        searchHealth: @escaping () -> SearchIndexer.Health = { .ready },
        onSelect: @escaping (Meeting) -> Void,
        onAsk: @escaping (String) -> Void = { _ in },
        onDismiss: @escaping () -> Void
    ) {
        self.meetingStore = meetingStore
        self.ftsMatches = ftsMatches
        self.searchHealth = searchHealth
        self.onSelect = onSelect
        self.onAsk = onAsk
        self.onDismiss = onDismiss
        meetingStore.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.recomputeMatches() }
            .store(in: &cancellables)
    }

    /// Forces a store scan, then recomputes. Called on open so a stale list from yesterday doesn't appear.
    /// The highlight resets to the top row too (UX25): the panel outlives its window, and a selection
    /// left three rows down last time would silently steer the first Return of the next open.
    func refresh() {
        meetingStore.start()
        selectedIndex = 0
        recomputeMatches()
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let next = min(max(selectedIndex + delta, 0), items.count - 1)
        selectedIndex = next
    }

    func selectCurrent() {
        guard let item = items[safe: selectedIndex] else { return }
        switch item {
        case .meeting(let match):
            onSelect(match.meeting)
        case .ask(let question):
            onAsk(question)
        }
        onDismiss()
    }

    /// UX25: ⌘↩ hands the typed query to Ask from anywhere in the panel, so the handoff never
    /// depends on scrolling past 50 results to reach the row.
    func askCurrentQuery() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        onAsk(q)
        onDismiss()
    }

    func cancel() {
        onDismiss()
    }

    private func recomputeMatches() {
        indexHealth = searchHealth()
        let m = QuickFindRanker.rank(
            query: query,
            in: meetingStore.meetings,
            ftsMatches: ftsMatches(query) ?? [],
            limit: 50
        )
        let rows = QuickFindList.items(query: query, matches: m)
        self.hasMeetingMatches = !m.isEmpty
        self.items = rows
        if rows.isEmpty {
            selectedIndex = 0
        } else if selectedIndex >= rows.count {
            selectedIndex = rows.count - 1
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
            searchHintStrip
            Divider()
            results
        }
        .frame(width: 520, height: 360)
        .background(.regularMaterial)
        .onAppear { queryFocused = true }
        // Background key handler so arrows/enter/esc work even when focus is in the search field.
        .background(
            KeyCatcher(
                onDown: { model.moveSelection(by: 1) },
                onUp: { model.moveSelection(by: -1) },
                onReturn: { model.selectCurrent() },
                onCommandReturn: { model.askCurrentQuery() },
                onEscape: { model.cancel() }
            )
        )
    }

    private var searchHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color(MPColors.fgMuted))
            TextField("Find a meeting…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.mpTextMD)
                .focused($queryFocused)
                .onSubmit { model.selectCurrent() }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    /// UX23: the same building/degraded hint the Library filter bar shows, so a Quick Find search
    /// over a still-building or degraded index explains why transcript matches may be missing. Shown
    /// only while the user is searching.
    @ViewBuilder
    private var searchHintStrip: some View {
        if !model.query.isEmpty, let hint = SearchIndexer.searchHint(for: model.indexHealth) {
            let degraded = model.indexHealth == .degraded
            HStack(spacing: 6) {
                Image(systemName: degraded ? "exclamationmark.triangle" : "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(degraded ? Color.mpWarning : Color(MPColors.fgSubtle))
                Text(hint)
                    .font(.mpTextXS)
                    .foregroundStyle(Color(MPColors.fgMuted))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private var results: some View {
        if model.items.isEmpty {
            VStack {
                Spacer()
                Text("Start typing to search the library.")
                    .font(.callout)
                    .foregroundStyle(Color(MPColors.fgSubtle))
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // UX25: a query with no meeting match is no longer a dead end, it is an
                        // Ask-only list, so the miss is stated instead of implied by an empty pane.
                        if !model.hasMeetingMatches {
                            Text("No meetings matched.")
                                .font(.mpTextSM)
                                .foregroundStyle(Color(MPColors.fgSubtle))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                        }
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { idx, item in
                            row(for: item, at: idx)
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

    @ViewBuilder
    private func row(for item: QuickFindItem, at idx: Int) -> some View {
        switch item {
        case .meeting(let match):
            QuickFindRow(match: match, isSelected: idx == model.selectedIndex)
        case .ask(let question):
            QuickFindAskRow(question: question, isSelected: idx == model.selectedIndex)
        }
    }
}

private struct QuickFindRow: View {
    let match: QuickFindRanker.Match
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(match.meeting.displayTitle)
                .font(.mpTextBase.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
            HStack(spacing: 6) {
                if let wf = match.meeting.workflowName, !wf.isEmpty {
                    Text(wf)
                        .font(.caption2)
                        .foregroundStyle(Color(MPColors.fgMuted))
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(Color(MPColors.fgSubtle))
                }
                Text(QuickFindRow.dateFormatter.string(from: match.meeting.startedAt))
                    .font(.caption2)
                    .foregroundStyle(Color(MPColors.fgMuted))
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(Color(MPColors.fgSubtle))
                Text(match.hitField)
                    .font(.caption2)
                    .foregroundStyle(Color(MPColors.fgSubtle))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected
            ? Color.mpSignal.opacity(0.25)
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

/// UX25: the "Ask about …" handoff row. Leads the list when the query ends in a question mark
/// and trails it otherwise; either way ⌘↩ reaches it from anywhere, which the trailing hint says
/// out loud so the shortcut is learnable without a tour.
private struct QuickFindAskRow: View {
    let question: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.mpTextBase)
                .foregroundStyle(Color.mpSignal)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ask about your meetings")
                    .font(.mpTextBase.weight(.medium))
                    .foregroundStyle(.primary)
                Text(question)
                    .font(.mpTextXS)
                    .lineLimit(1)
                    .foregroundStyle(Color(MPColors.fgMuted))
            }
            Spacer(minLength: 8)
            Text("⌘↩")
                .font(.mpTextXS)
                .foregroundStyle(Color(MPColors.fgSubtle))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected
            ? Color.mpSignal.opacity(0.25)
            : Color.clear
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ask about your meetings: \(question)")
    }
}

/// Invisible NSView that intercepts arrow/return/escape so the TextField keeps focus while the panel drives list selection.
private struct KeyCatcher: NSViewRepresentable {
    let onDown: () -> Void
    let onUp: () -> Void
    let onReturn: () -> Void
    let onCommandReturn: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> KeyCatcherView {
        let v = KeyCatcherView()
        v.onDown = onDown
        v.onUp = onUp
        v.onReturn = onReturn
        v.onCommandReturn = onCommandReturn
        v.onEscape = onEscape
        return v
    }

    func updateNSView(_ nsView: KeyCatcherView, context: Context) {
        nsView.onDown = onDown
        nsView.onUp = onUp
        nsView.onReturn = onReturn
        nsView.onCommandReturn = onCommandReturn
        nsView.onEscape = onEscape
    }
}

private final class KeyCatcherView: NSView {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    var onReturn: (() -> Void)?
    var onCommandReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let command = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.command)
        switch Int(event.keyCode) {
        case 125: onDown?(); return true  // arrow down
        case 126: onUp?(); return true    // arrow up
        case 36:                          // return, ⌘↩ asks (UX25)
            if command { onCommandReturn?() } else { onReturn?() }
            return true
        case 53:  onEscape?(); return true // escape
        default:  return super.performKeyEquivalent(with: event)
        }
    }
}
