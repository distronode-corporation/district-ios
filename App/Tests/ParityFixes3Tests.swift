@testable import DistrictAI
import XCTest

/// The third round of parity fixes: the Phone numbers tabs on a narrow phone in French.
/// The look is the screenshots' to prove; this holds the rule behind it.
final class ParityFixes3Tests: XCTestCase {
    /// ⛔ THE SEGMENTED CONTROL ONLY WHEN ITS FOUR LABELS FIT, the menu otherwise. On an
    /// iPhone 16e in French the control cut « Mes numéros » to « Mes numér… ». The fit is
    /// measured on the labels, because the control's own ideal width (four equal segments)
    /// rejected it even where the labels fitted.
    func test_PF3_01_theTabsFallBackToTheMenuWhenTheLabelsDoNotFit() throws {
        let file = try SourceScan.sourceRoot().appendingPathComponent("Features/Marketplace/MarketplaceView.swift")
        let code = try SourceScan.stripComments(String(contentsOf: file, encoding: .utf8))
        let segments = try XCTUnwrap(
            code.components(separatedBy: "private var segments: some View").dropFirst().first?
                .components(separatedBy: "private var segmentLabels").first
        )
        XCTAssertTrue(segments.contains("if dynamicTypeSize.isAccessibilitySize {\n            tabMenu"))
        XCTAssertTrue(segments.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(segments.contains("segmentLabels\n                    .hidden()"), "the fit is measured on the labels")
        XCTAssertTrue(segments.contains(".pickerStyle(.segmented)"))
        let fallback = try XCTUnwrap(segments.components(separatedBy: ".pickerStyle(.segmented)").last)
        XCTAssertTrue(fallback.contains("tabMenu"), "the menu is the fallback")
        let labels = try XCTUnwrap(code.components(separatedBy: "private var segmentLabels").dropFirst().first?.prefix(500))
        XCTAssertTrue(labels.contains("MarketplaceTab.allCases"), "every tab is measured")
        XCTAssertTrue(labels.contains(".lineLimit(1)"))
        XCTAssertTrue(labels.contains(".fixedSize()"))
    }
}
