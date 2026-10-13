@testable import DistrictAI
import DistrictL10n
import XCTest

/// The app's language decision (``AppL10n``) and the catalog reader the store gate uses.
final class AppL10nTests: XCTestCase {
    // MARK: - Which language

    /// ⛔ THE GATE THAT KEEPS FRENCH OFF: a build that ships no French answers English to a
    /// French device, because the core's formatters are already French.
    func testABuildWithoutFrenchIsEnglishOnAFrenchDevice() {
        XCTAssertEqual(
            AppL10n.resolve(
                preferredLocalizations: ["en"],
                preferredLanguages: ["fr-CA", "en"],
                bundleLocalizations: ["en"]
            ),
            .en
        )
        XCTAssertEqual(
            AppL10n.resolve(preferredLocalizations: [], preferredLanguages: ["fr-FR"], bundleLocalizations: []),
            .en
        )
    }

    func testABuildWithFrenchFollowsTheBundlesChoice() {
        XCTAssertEqual(
            AppL10n.resolve(
                preferredLocalizations: ["fr-CA"],
                preferredLanguages: ["fr-BE", "en"],
                bundleLocalizations: ["en", "fr-CA"]
            ),
            .frCA
        )
        XCTAssertEqual(
            AppL10n.resolve(
                preferredLocalizations: ["en"],
                preferredLanguages: ["en-US", "fr-CA"],
                bundleLocalizations: ["en", "fr-CA"]
            ),
            .en
        )
    }

    /// The generated accessors read the core's language, task-local override included.
    func testTheCopyLocaleIsTheCoresLocale() {
        XCTAssertEqual(L10nRuntime.withLocale(.frCA) { AppL10n.copyLocale }, .frCA)
        XCTAssertEqual(L10nRuntime.withLocale(.en) { AppL10n.copyLocale }, .en)
    }

    // MARK: - The catalog reader

    func testTheCatalogReaderDecodesEscapes() {
        XCTAssertEqual(CatalogScan.basicString(#""a \"b\" c\\d\nA\u00A0B""#), "a \"b\" c\\d\nA\u{00A0}B")
        XCTAssertNil(CatalogScan.basicString(#""unterminated"#))
        XCTAssertNil(CatalogScan.basicString(#""bad \q escape""#))
    }

    func testTheCatalogReaderReadsTheWholeCatalog() throws {
        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // App/Tests
            .deletingLastPathComponent() // App
            .deletingLastPathComponent() // the checkout
            .appendingPathComponent("l10n/ios.toml")
        let entries = try CatalogScan.entries(of: catalog)
        XCTAssertGreaterThan(entries.count, 1000)
        XCTAssertTrue(entries.allSatisfy { !$0.english.isEmpty && !$0.screen.isEmpty })
        XCTAssertEqual(
            entries.first { $0.key == "billing.read_only" }?.english,
            [BillingCopy.readOnly]
        )
    }
}
