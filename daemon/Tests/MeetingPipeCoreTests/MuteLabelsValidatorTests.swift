import XCTest
@testable import MeetingPipeCore

final class MuteLabelsValidatorTests: XCTestCase {

    func test_clean_report_when_every_probe_finds_a_known_label() throws {
        let catalogue = try MuteLabelsLoader.loadDefault()
        let validator = MuteLabelsValidator(catalogue: catalogue)
        let probes: [MuteLabelsValidator.Probe] = [
            .init(bundleID: "com.microsoft.teams2", app: "teams", locale: "en",
                  scrape: { ["Unmute"] }),
            .init(bundleID: "us.zoom.xos", app: "zoom", locale: "de",
                  scrape: { ["Audio einschalten"] })
        ]
        let report = validator.validate(probes)
        XCTAssertTrue(report.isClean)
    }

    func test_missing_app_install_surfaces_finding() throws {
        let catalogue = try MuteLabelsLoader.loadDefault()
        let validator = MuteLabelsValidator(catalogue: catalogue)
        let probes: [MuteLabelsValidator.Probe] = [
            .init(bundleID: "com.microsoft.teams2", app: "teams", locale: "en",
                  scrape: { nil })
        ]
        let report = validator.validate(probes)
        XCTAssertEqual(report.findings.count, 1)
        XCTAssertEqual(report.findings[0].reason, .appNotInstalled)
    }

    func test_label_drift_surfaces_no_match_finding() throws {
        let catalogue = try MuteLabelsLoader.loadDefault()
        let validator = MuteLabelsValidator(catalogue: catalogue)
        let probes: [MuteLabelsValidator.Probe] = [
            .init(bundleID: "com.microsoft.teams2", app: "teams", locale: "en",
                  scrape: { ["Vendor renamed this label"] })
        ]
        let report = validator.validate(probes)
        XCTAssertEqual(report.findings.count, 1)
        if case .noTomlLabelMatched(let scraped) = report.findings[0].reason {
            XCTAssertEqual(scraped, ["Vendor renamed this label"])
        } else {
            XCTFail("Expected .noTomlLabelMatched, got \(report.findings[0].reason)")
        }
    }

    func test_missing_toml_entry_for_locale_surfaces_finding() throws {
        let catalogue = MuteLabels(entries: [:])
        let validator = MuteLabelsValidator(catalogue: catalogue)
        let probes: [MuteLabelsValidator.Probe] = [
            .init(bundleID: "com.microsoft.teams2", app: "teams", locale: "ja",
                  scrape: { ["何か"] })
        ]
        let report = validator.validate(probes)
        XCTAssertEqual(report.findings.count, 1)
        XCTAssertEqual(report.findings[0].reason, .noTomlEntry)
    }
}
