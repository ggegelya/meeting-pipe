import Foundation
import TOMLKit

/// Single source of truth for the meeting-app bundle lists that drive discovery (DET4).
///
/// Loads the bundled `meeting_apps.toml` and, layered on top, an optional user overlay at
/// `~/.config/meeting-pipe/meeting_apps.toml`, so the owner can add a bundle without a
/// rebuild (relaunch, like `config.toml`). `MeetingSourceScanner` reads its native / browser /
/// fragment sets from here; `Coordinator` reads the browser set to construct the browser
/// lifecycle adapter over the *same* set discovery enumerates (so a listed browser can never be
/// discovered-but-adapterless), and the mic-plausible set for DET1's catch-all attribution.
///
/// The bundled data is fenced by `MeetingAppRegistryFenceTests`: every `[native]` bundle must
/// have a `NativeLifecycleConfig` and a recognizer branch, and `[browser.bundles]` must equal
/// `BrowserMeetingLifecycleAdapter.defaultBrowserBundleIDs`. The `[mic_plausible]` tier is
/// adapterless by design and exempt from that fence.
struct MeetingAppRegistry {
    /// Native meeting-app bundle IDs with a lifecycle adapter + recognizer.
    let nativeBundles: Set<String>
    /// Browser bundle IDs whose windows we inspect for a meeting tab.
    let browserBundles: Set<String>
    /// Meeting-URL fragments (lowercased) used to recognise a browser meeting tab.
    let browserURLFragments: [String]
    /// Adapterless audio/meeting-capable apps for DET1's mic-in-use tier (naming only).
    let micPlausibleBundles: Set<String>

    /// Process-wide registry: bundled defaults unioned with the user overlay. Loaded once.
    static let shared = MeetingAppRegistry.load(overlayURL: defaultOverlayURL)

    /// Bundled defaults only (no overlay). Used by the coverage fence so the shipped data is
    /// asserted consistent regardless of any overlay present on the machine running the tests.
    static let bundled = MeetingAppRegistry.load(overlayURL: nil)

    /// `~/.config/meeting-pipe/meeting_apps.toml`, the same config root as `config.toml`.
    static var defaultOverlayURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/meeting-pipe/meeting_apps.toml")
    }

    // MARK: - Loading

    /// Parse the bundled TOML, then union an optional overlay on top. Missing / malformed
    /// overlay is ignored (defaults still load); a missing bundled resource degrades to empty
    /// lists, exactly as the scanner did before DET4.
    static func load(overlayURL: URL?) -> MeetingAppRegistry {
        var lists = parse(tomlString: bundledTOMLString()) ?? Lists()
        if let overlayURL,
           let data = try? String(contentsOf: overlayURL, encoding: .utf8),
           let overlay = parse(tomlString: data) {
            lists.formUnion(overlay)
        }
        return MeetingAppRegistry(
            nativeBundles: lists.native,
            browserBundles: lists.browsers,
            browserURLFragments: Array(lists.urlFragments),
            micPlausibleBundles: lists.micPlausible
        )
    }

    private static func bundledTOMLString() -> String? {
        guard let url = Bundle.module.url(forResource: "meeting_apps", withExtension: "toml"),
              let data = try? String(contentsOf: url, encoding: .utf8) else {
            Log.detector.warning("meeting_apps.toml not found; using empty lists")
            return nil
        }
        return data
    }

    /// Ordered, de-duplicated accumulator so overlay entries append after the defaults but never
    /// duplicate. `urlFragments` keeps insertion order (fragment matching is order-independent,
    /// but a stable order keeps logs readable); the bundle sets are unordered.
    private struct Lists {
        var native: Set<String> = []
        var browsers: Set<String> = []
        var urlFragments: [String] = []
        var micPlausible: Set<String> = []

        mutating func formUnion(_ other: Lists) {
            native.formUnion(other.native)
            browsers.formUnion(other.browsers)
            for f in other.urlFragments where !urlFragments.contains(f) { urlFragments.append(f) }
            micPlausible.formUnion(other.micPlausible)
        }
    }

    private static func parse(tomlString: String?) -> Lists? {
        guard let tomlString, let toml = try? TOMLTable(string: tomlString) else { return nil }
        let native = toml["native"]?.table?["bundle_ids"]?.array?.compactMap { $0.string } ?? []
        let urls = toml["browser"]?.table?["url_fragments"]?.array?.compactMap { $0.string } ?? []
        let browsers = toml["browser"]?.table?["bundles"]?.table?["ids"]?.array?.compactMap { $0.string } ?? []
        let micPlausible = toml["mic_plausible"]?.table?["bundle_ids"]?.array?.compactMap { $0.string } ?? []
        return Lists(
            native: Set(native),
            browsers: Set(browsers),
            urlFragments: urls.map { $0.lowercased() },
            micPlausible: Set(micPlausible)
        )
    }
}
