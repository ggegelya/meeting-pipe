import Foundation

/// CI validator for `MuteLabels.toml`. Scrapes each app's AX subtree per locale and asserts at least one TOML label per category resolves; label drift (vendor renames a button) fails the job. Probe is injected for unit-testability without live AX. API surface landed in step 2; CI driver with remaining locales lands in step 6.
public final class MuteLabelsValidator {

    public struct Probe {
        public let bundleID: String
        public let app: String
        public let locale: String

        /// Returns recognised AX labels for the app's mute button, or nil if not installed / AX denied.
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
