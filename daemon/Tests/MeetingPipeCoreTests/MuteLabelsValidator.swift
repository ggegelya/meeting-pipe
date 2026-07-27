import Foundation
import MeetingPipeCore

/// Drift checker for `MuteLabels.toml`, and the engine of `MuteLabelsValidatorTests`. Given a set of probes (one per app + locale, each returning that app's recognised AX labels), it asserts at least one TOML label resolves, so a vendor renaming a button surfaces as a finding rather than as a mic gate that silently stops recognising mute.
///
/// It lives in the test target because that is the only thing that runs it. There is no live-AX driver and never has been: the real guard is `swift test` on every CI push, where the tests feed synthetic scrapes against the *bundled* catalogue (`MuteLabelsLoader.loadDefault()`), which is what makes a malformed or emptied `MuteLabels.toml` fail the suite. Scraping installed apps in eight locales would need a machine with Teams, Zoom, Webex, and Slack installed in each; that is not something this repo has.
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
