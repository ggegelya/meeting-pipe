import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One app a workflow rule or the auto-record allowlist can name (UX88). The stored value stays
/// the bundle id; the name is only what the person reads.
struct MeetingAppChoice: Equatable, Identifiable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
}

/// The apps the picker offers, merged without duplicates (UX88): the meeting apps the registry
/// knows (native apps and the browsers whose tabs it inspects, since a title rule is how one
/// browser is split into per-tab workflows), every app the library has seen as a meeting source,
/// and the ids already chosen, so a hand-typed or since-uninstalled app is never blanked or
/// dropped. Pure: names come from the library's own display names first, then `resolveName`
/// (NSWorkspace in the app), then the id itself.
enum MeetingAppChoices {
    static func merge(
        registry: [String],
        librarySources: [String: String],
        current: [String],
        resolveName: (String) -> String?
    ) -> [MeetingAppChoice] {
        var seen = Set<String>()
        var out: [MeetingAppChoice] = []
        for id in registry + librarySources.keys.sorted() + current {
            let trimmed = id.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            let name = librarySources[trimmed].flatMap { $0.isEmpty ? nil : $0 }
                ?? resolveName(trimmed)
                ?? trimmed
            out.append(MeetingAppChoice(bundleID: trimmed, name: name))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// What the auto-record allowlist's picker does not offer: the apps already on it, and the
    /// browsers, which the allowlist cannot act on (DET17 guard 1: a browser source always prompts,
    /// whatever the list says), so offering one would be an option whose setting drops it.
    static func allowlistExclusions(current: [String], browsers: Set<String>) -> Set<String> {
        Set(current).union(browsers)
    }

    /// The registry's half: native meeting apps and the listed browsers.
    static var registryBundles: [String] {
        let registry = MeetingAppRegistry.shared
        return Array(registry.nativeBundles).sorted() + Array(registry.browserBundles).sorted()
    }
}

/// Bundle id to installed app name and icon, through Launch Services. Cached for the process, and
/// only ever asked from a picker's `.onAppear` or a menu action, never from a `body`.
@MainActor
enum InstalledApps {
    private static var names: [String: String?] = [:]
    private static var icons: [String: NSImage?] = [:]

    static func name(for bundleID: String) -> String? {
        if let cached = names[bundleID] { return cached }
        let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
            FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
        }
        names[bundleID] = name
        return name
    }

    static func icon(for bundleID: String) -> NSImage? {
        if let cached = icons[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { url -> NSImage in
            let image = NSWorkspace.shared.icon(forFile: url.path)
            image.size = NSSize(width: 16, height: 16)
            return image
        }
        icons[bundleID] = icon
        return icon
    }

    /// **Other app…**: an application chooser on `/Applications`, answering the chosen bundle's id.
    static func chooseApplication() -> String? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.prompt = "Choose"
        panel.message = "Pick the app the meeting runs in."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }
}

/// The shared app picker (UX88), used by the workflow editor's matching rules and by Preferences ▸
/// Recording's auto-record allowlist in place of a raw bundle-id text field. A menu of apps by name
/// and icon, plus **Other app…**. Names and icons are resolved once on appear, never per render.
struct MeetingAppPicker: View {
    /// The chosen id for a rule row ("" is Any app), or nil for a picker that only adds (the
    /// allowlist), whose label is then always `placeholder`.
    let selection: String?
    /// The label when nothing is chosen.
    let placeholder: String
    /// Bundle ids to offer beyond the registry: the library's meeting sources, id to display name.
    let librarySources: [String: String]
    /// Ids already chosen, kept as options even when nothing else knows them.
    let current: [String]
    /// Offer "Any app" (a blank bundle id), which a title-only rule means.
    var offersAnyApp: Bool = false
    /// Ids not to offer (the allowlist hides the apps already on it).
    var excluding: Set<String> = []
    /// The chosen id, or "" for Any app.
    let onPick: (String) -> Void

    @State private var choices: [MeetingAppChoice] = []
    @State private var icons: [String: NSImage] = [:]

    var body: some View {
        Menu {
            if offersAnyApp {
                Button("Any app") { onPick("") }
                Divider()
            }
            ForEach(choices.filter { !excluding.contains($0.bundleID) }) { choice in
                Button {
                    onPick(choice.bundleID)
                } label: {
                    if let icon = icons[choice.bundleID] {
                        Label { Text(choice.name) } icon: { Image(nsImage: icon) }
                    } else {
                        Text(choice.name)
                    }
                }
            }
            Divider()
            Button("Other app\u{2026}") {
                if let id = InstalledApps.chooseApplication() { onPick(id) }
            }
        } label: {
            Text(label).lineLimit(1)
        }
        .fixedSize()
        .help(selection.flatMap { $0.isEmpty ? nil : $0 } ?? "")
        .onAppear { reload() }
        .onChange(of: current) { _, _ in reload() }
    }

    private var label: String {
        guard let selection else { return placeholder }
        if selection.isEmpty { return offersAnyApp ? "Any app" : placeholder }
        return choices.first { $0.bundleID == selection }?.name ?? selection
    }

    private func reload() {
        choices = MeetingAppChoices.merge(
            registry: MeetingAppChoices.registryBundles,
            librarySources: librarySources,
            current: current,
            resolveName: { InstalledApps.name(for: $0) }
        )
        var resolved: [String: NSImage] = [:]
        for choice in choices {
            if let icon = InstalledApps.icon(for: choice.bundleID) { resolved[choice.bundleID] = icon }
        }
        icons = resolved
    }
}
