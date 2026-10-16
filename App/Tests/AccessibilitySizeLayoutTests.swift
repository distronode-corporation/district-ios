@testable import DistrictAI
import DistrictL10n
import DistrictModel
import SwiftUI
import XCTest

/// The 3.0.1 visual-QA fixes for the largest text sizes, iPad portrait and a failed Overview
/// (AP-002, AP-004, AP-005, AP-013, AP-014, AP-019). The look is proved by the capture walk's
/// frames; these hold the rules behind it.
final class AccessibilitySizeLayoutTests: XCTestCase {
    private func source(_ relative: String) throws -> String {
        let file = try SourceScan.sourceRoot().appendingPathComponent(relative)
        return try SourceScan.stripComments(String(contentsOf: file, encoding: .utf8))
    }

    /// ⛔ AP-002, AND SINCE 3.0.2 AT EVERY SIZE (AP-011): THE EYEBROW IS THE TEXT AS WRITTEN,
    /// with no capitals and no tracking, so it wraps between words.
    func test_AX_01_theEyebrowIsTheTextAsWritten() throws {
        let code = try source("DesignSystem/DistrictType.swift")
        let eyebrow = try XCTUnwrap(code.components(separatedBy: "struct DistrictEyebrow").last)
        XCTAssertFalse(eyebrow.contains(".uppercased()"))
        XCTAssertFalse(eyebrow.contains(".tracking("))
        XCTAssertTrue(eyebrow.contains("Text(text)"))
    }

    /// ⛔ AP-002: THE METRIC GRIDS ARE BUILT FROM ``DistrictMetricRow``, which stacks at an
    /// accessibility size, and no tile row is a bare `HStack` any more.
    func test_AX_02_theMetricGridsGoToOneColumn() throws {
        for file in ["Features/Overview/OverviewView.swift", "Features/Analytics/AnalyticsCards.swift"] {
            let code = try source(file)
            XCTAssertEqual(code.components(separatedBy: "DistrictMetricRow {").count - 1, 2, file)
            XCTAssertFalse(
                code.contains("HStack(spacing: DistrictSpacing.row) {\n                DistrictMetricTile("),
                file
            )
        }
    }

    /// ⛔ AP-005: A PILL WRAPS ONLY AT AN ACCESSIBILITY SIZE.
    func test_AX_03_aPillWrapsOnlyAtAccessibilitySizes() {
        XCTAssertFalse(DistrictBadge.wraps(.large))
        XCTAssertFalse(DistrictBadge.wraps(.xxxLarge))
        XCTAssertTrue(DistrictBadge.wraps(.accessibility1))
        XCTAssertTrue(DistrictBadge.wraps(.accessibility5))
    }

    /// ⚠️ AP-013: THE AVATAR'S SIDE IS A SCALED METRIC, so the initials fit at AX5.
    func test_AX_04_theAvatarGrowsWithItsInitials() throws {
        let code = try source("DesignSystem/DistrictListRow.swift")
        XCTAssertTrue(code.contains("@ScaledMetric(relativeTo: .caption) private var side: CGFloat = 36"))
        XCTAssertTrue(code.contains(".frame(width: side, height: side)"))
    }

    /// ⛔ AP-014: A LIST SECTION IN PORTRAIT OPENS ON ITS LIST AND THE OPEN ROW; landscape and
    /// every other section keep the system's choice.
    func test_AX_05_aListSectionInPortraitShowsTheList() {
        XCTAssertEqual(RegularShellView.visibility(listSection: true, portrait: true), .doubleColumn)
        XCTAssertEqual(RegularShellView.visibility(listSection: true, portrait: false), .automatic)
        XCTAssertEqual(RegularShellView.visibility(listSection: false, portrait: true), .automatic)
        XCTAssertEqual(RegularShellView.visibility(listSection: false, portrait: false), .automatic)
    }

    /// ⛔ AP-004: THE FUNNEL'S AXIS IS ITS BARS' OWN LABELS, in the server's order, in both
    /// languages, so every bar lands on a category. The domain was the wire names, which no
    /// bar matched in French.
    func test_AX_06_theFunnelAxisIsTheBarsLabels() throws {
        let names = ["total dials", "connected calls", "successful leads"]
        let json = Data(("[" + names.map { #"{"name":"\#($0)","count":1}"# }.joined(separator: ",") + "]").utf8)
        let stages = try JSONDecoder().decode([FunnelStage].self, from: json)
        for locale in [L10nLocale.en, .frCA] {
            L10nRuntime.withLocale(locale) {
                let domain = AnalyticsFunnelCard.axisDomain(stages)
                XCTAssertEqual(domain, stages.map { AnalyticsFunnelCard.axisLabel($0) }, "\(locale)")
                XCTAssertEqual(Set(domain).count, 3, "\(locale)")
            }
        }
        L10nRuntime.withLocale(.frCA) {
            XCTAssertTrue(Set(AnalyticsFunnelCard.axisDomain(stages)).isDisjoint(with: [
                "total dials",
                "connected calls",
                "successful leads",
            ]))
        }
    }

    /// ⛔ AP-019: THE FAILED OVERVIEW STILL OFFERS THE SECTION ROWS.
    func test_AX_07_aFailedOverviewKeepsTheSectionRows() throws {
        let code = try source("Features/Overview/OverviewView.swift")
        let failed = try XCTUnwrap(code.range(of: "case let .failed(failure):"))
        let content = try XCTUnwrap(code.range(of: "case let .content(response, _):"))
        let branch = code[failed.upperBound ..< content.lowerBound]
        XCTAssertTrue(branch.contains("entryPoints(workspaceId: workspaceId, role: workspaceSession.role)"))
    }
}
