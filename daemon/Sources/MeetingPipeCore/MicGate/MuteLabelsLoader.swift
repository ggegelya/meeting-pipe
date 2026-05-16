import Foundation
import TOMLKit

/// Catalogue of localised mute / unmute labels per meeting client.
/// Built from `MuteLabels.toml` shipped as a resource of
/// `MeetingPipeCore`.
///
/// `recognize(bundleID:locale:title:help:description:)` is the
/// AX-side entry point: it takes a button's AX text blob plus the
/// active locale and returns a `Mute.State`. Used by
/// `AXMuteButtonProbe` (TECH-G-MIC step 3) when the locale's catalogue
/// resolves; falls through to `.unknown` for unsupported app/locale
/// pairs.
///
/// The loader does not interpret strings beyond case-insensitive
/// substring matching with explicit precedence: status_muted /
/// status_unmuted phrases beat action_unmute / action_mute because
/// the status phrases are unambiguous (the action verbs are
/// substrings of each other in some locales, e.g. "unmute" inside
/// "unmuted").
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

    /// Keyed by app name (lowercase) -> locale -> entry. Apps are
    /// the short names in the TOML (`teams`, `zoom`, `slack`, etc.),
    /// distinct from bundle IDs.
    public let entries: [String: [String: AppEntry]]

    public init(entries: [String: [String: AppEntry]]) {
        self.entries = entries
    }

    /// Entry for a given app + locale. Returns nil when either is
    /// not in the catalogue. The caller decides whether to fall
    /// through to RMS-only gating in that case.
    public func entry(app: String, locale: String) -> AppEntry? {
        entries[app.lowercased()]?[locale.lowercased()]
    }

    /// Recognise the AX text blob against the (app, locale) entry.
    /// Returns `.unknown` when the entry is missing or the blob
    /// matches no labels.
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

        if entry.statusMuted.contains(where: { blob.contains($0.lowercased()) }) { return .muted }
        if entry.statusUnmuted.contains(where: { blob.contains($0.lowercased()) }) { return .unmuted }
        if entry.actionUnmute.contains(where: { blob.contains($0.lowercased()) }) { return .muted }
        if entry.actionMute.contains(where: { blob.contains($0.lowercased()) }) { return .unmuted }
        return .unknown
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

    /// Load the catalogue from `MuteLabels.toml` shipped with the
    /// `MeetingPipeCore` resource bundle.
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

    /// Parse an arbitrary TOML string. Useful for tests that want to
    /// pin specific catalogue contents.
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
