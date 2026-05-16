import Foundation

/// Validator skeleton for `MuteLabels.toml`. The shipping form runs
/// in CI: it scrapes each meeting app's AX subtree per locale and
/// asserts that at least one TOML label per category resolves. Label
/// drift (vendor renames a button across a version bump) fails the
/// CI job and surfaces the missing entry for a TOML update.
///
/// The probe is injected so the validator type is unit-testable
/// without driving live AX. Production wires a probe that runs an
/// AX walk for the given app + locale and returns the recognised
/// labels; the validator compares them against the TOML entry.
///
/// Step 2 ships the API surface plus a test that locks in the
/// "missing entry -> failure" path. The CI driver lands in step 6
/// alongside the remaining locales.
public final class MuteLabelsValidator {

    public struct Probe {
        public let bundleID: String
        public let app: String
        public let locale: String

        /// Returns the recognised labels (title / help / description)
        /// for the app's mute button under the given locale. Nil
        /// when the app isn't installed or AX denied.
        public let scrape: () -> [String]?

        public init(
            bundleID: String,
            app: String,
            locale: String,
            scrape: @escaping () -> [String]?
        ) {
            self.bundleID = bundleID
            self.app = app
            self.locale = locale
            self.scrape = scrape
        }
    }

    public struct Report: Equatable {
        public struct Finding: Equatable {
            public let bundleID: String
            public let app: String
            public let locale: String
            public let reason: Reason

            public enum Reason: Equatable {
                case appNotInstalled
                case noTomlEntry
                case noTomlLabelMatched(scraped: [String])
            }
        }

        public let findings: [Finding]
        public var isClean: Bool { findings.isEmpty }
    }

    private let catalogue: MuteLabels

    public init(catalogue: MuteLabels) {
        self.catalogue = catalogue
    }

    public func validate(_ probes: [Probe]) -> Report {
        var findings: [Report.Finding] = []
        for probe in probes {
            guard let scraped = probe.scrape() else {
                findings.append(.init(
                    bundleID: probe.bundleID,
                    app: probe.app,
                    locale: probe.locale,
                    reason: .appNotInstalled
                ))
                continue
            }
            guard let entry = catalogue.entry(app: probe.app, locale: probe.locale),
                  !entry.isEmpty else {
                findings.append(.init(
                    bundleID: probe.bundleID,
                    app: probe.app,
                    locale: probe.locale,
                    reason: .noTomlEntry
                ))
                continue
            }
            let allLabels = entry.actionUnmute + entry.actionMute
                + entry.statusMuted + entry.statusUnmuted
            let scrapedLower = scraped.map { $0.lowercased() }
            let anyMatch = allLabels.contains { label in
                scrapedLower.contains { $0.contains(label.lowercased()) }
            }
            if !anyMatch {
                findings.append(.init(
                    bundleID: probe.bundleID,
                    app: probe.app,
                    locale: probe.locale,
                    reason: .noTomlLabelMatched(scraped: scraped)
                ))
            }
        }
        return Report(findings: findings)
    }
}
