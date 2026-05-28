import Foundation
import TOMLKit

/// Localised mute/unmute label catalogue per meeting client, loaded from `MuteLabels.toml`. `recognize` takes a button's AX text blob and active locale and returns `MuteLabels.State` (used by `AXMuteButtonProbe`, TECH-G-MIC step 3). Matching is case-insensitive with explicit precedence: status_muted/status_unmuted beat action_unmute/action_mute because the action verbs are substrings of each other in some locales (e.g. "unmute" inside "unmuted").
public struct MuteLabels {

    public enum State: Equatable {
        case muted
        case unmuted
        case unknown
    }

    public struct AppEntry: Equatable {
        public let actionUnmute: [String]
        public let actionMute: [String]
        public let statusMuted: [String]
        public let statusUnmuted: [String]

        public init(
            actionUnmute: [String] = [],
            actionMute: [String] = [],
            statusMuted: [String] = [],
            statusUnmuted: [String] = []
        ) {
            self.actionUnmute = actionUnmute
            self.actionMute = actionMute
            self.statusMuted = statusMuted
            self.statusUnmuted = statusUnmuted
        }

        public var isEmpty: Bool {
            actionUnmute.isEmpty && actionMute.isEmpty &&
                statusMuted.isEmpty && statusUnmuted.isEmpty
        }
    }

    /// Keyed by app short name (lowercase, e.g. `teams`, `zoom`) -> locale -> entry. Distinct from bundle IDs.
    public let entries: [String: [String: AppEntry]]

    public init(entries: [String: [String: AppEntry]]) {
        self.entries = entries
    }

    /// Entry for the given app + locale, or nil (caller falls through to RMS-only gating).
    public func entry(app: String, locale: String) -> AppEntry? {
        entries[app.lowercased()]?[locale.lowercased()]
    }

    /// Recognise the AX text blob against the (app, locale) entry. Returns `.unknown` when missing or no label matched.
    public func recognize(
        app: String,
        locale: String,
        title: String?,
        help: String?,
        description: String?
    ) -> State {
        guard let entry = entry(app: app, locale: locale) else { return .unknown }
        let blob = [title, help, description]
            .compactMap { $0?.lowercased() }
            .joined(separator: " | ")
        if blob.isEmpty { return .unknown }

        if entry.statusMuted.contains(where: { MuteLabels.containsAsWord(blob: blob, label: $0) }) { return .muted }
        if entry.statusUnmuted.contains(where: { MuteLabels.containsAsWord(blob: blob, label: $0) }) { return .unmuted }
        if entry.actionUnmute.contains(where: { MuteLabels.containsAsWord(blob: blob, label: $0) }) { return .muted }
        if entry.actionMute.contains(where: { MuteLabels.containsAsWord(blob: blob, label: $0) }) { return .unmuted }
        return .unknown
    }

    /// Word-boundary substring check: true if `label` appears in `blob` flanked by non-letter characters or string boundaries. Replaces a plain `contains` that spuriously muted the mic for 25 min during the 2026-05-20 Teams meeting: Teams 2 exposes a status indicator (`kAXTitleAttribute = "Unmuted (⌥ ⌘ Q)"`) alongside the toggle button; `"unmute"` matched the `"Unmuted"` prefix and `recognize` mis-classified the indicator as `actionUnmute` (meaning "user is muted"). Word boundaries make "Unmute" reject "Unmuted" because the trailing `d` is a letter. `blob` is expected lowercased; `label` is lowercased defensively.
    public static func containsAsWord(blob: String, label: String) -> Bool {
        let needle = label.lowercased()
        guard !needle.isEmpty else { return false }
        var searchStart = blob.startIndex
        while searchStart < blob.endIndex,
              let range = blob.range(of: needle, range: searchStart..<blob.endIndex) {
            let beforeOk: Bool = {
                guard range.lowerBound > blob.startIndex else { return true }
                return !blob[blob.index(before: range.lowerBound)].isLetter
            }()
            let afterOk: Bool = {
                guard range.upperBound < blob.endIndex else { return true }
                return !blob[range.upperBound].isLetter
            }()
            if beforeOk && afterOk { return true }
            searchStart = blob.index(after: range.lowerBound)
        }
        return false
    }
}

public enum MuteLabelsLoader {

    public enum Error: Swift.Error, LocalizedError {
        case resourceMissing
        case parseFailed(String)

        public var errorDescription: String? {
            switch self {
            case .resourceMissing:
                return "MuteLabels.toml is not present in the MeetingPipeCore bundle"
            case .parseFailed(let detail):
                return "MuteLabels.toml parse failed: \(detail)"
            }
        }
    }

    /// Load the catalogue from `MuteLabels.toml` in the `MeetingPipeCore` bundle.
    public static func loadDefault() throws -> MuteLabels {
        try loadDefault(bundle: .module)
    }

    static func loadDefault(bundle: Bundle) throws -> MuteLabels {
        guard let url = bundle.url(forResource: "MuteLabels", withExtension: "toml") else {
            throw Error.resourceMissing
        }
        let data = try Data(contentsOf: url)
        guard let toml = String(data: data, encoding: .utf8) else {
            throw Error.parseFailed("not utf-8")
        }
        return try load(tomlString: toml)
    }

    /// Parse an arbitrary TOML string (for tests pinning specific catalogue contents).
    public static func load(tomlString: String) throws -> MuteLabels {
        let table: TOMLTable
        do {
            table = try TOMLTable(string: tomlString)
        } catch {
            throw Error.parseFailed(String(describing: error))
        }
        var entries: [String: [String: MuteLabels.AppEntry]] = [:]
        for (appName, appValue) in table {
            guard let appTable = appValue.table else { continue }
            var localeMap: [String: MuteLabels.AppEntry] = [:]
            for (locale, localeValue) in appTable {
                guard let localeTable = localeValue.table else { continue }
                let entry = MuteLabels.AppEntry(
                    actionUnmute: stringArray(localeTable["action_unmute"]),
                    actionMute: stringArray(localeTable["action_mute"]),
                    statusMuted: stringArray(localeTable["status_muted"]),
                    statusUnmuted: stringArray(localeTable["status_unmuted"])
                )
                localeMap[locale.lowercased()] = entry
            }
            entries[appName.lowercased()] = localeMap
        }
        return MuteLabels(entries: entries)
    }

    private static func stringArray(_ value: TOMLValueConvertible?) -> [String] {
        guard let array = value?.array else { return [] }
        return array.compactMap { $0.string }
    }
}
