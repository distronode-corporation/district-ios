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

    /// ⛔ THE PIN EVERY ENGLISH ASSERTION IN THIS BUNDLE STANDS ON (``EnglishTestLocale``).
    func testEveryTestRunsInEnglish() {
        XCTAssertEqual(L10nRuntime.locale, .en)
        XCTAssertEqual(AppL10n.copyLocale, .en)
    }

    /// ⛔ THE UI TESTS FIND A TAB BY ITS ENGLISH LABEL (a SwiftUI tab item carries no
    /// identifier), from `A11yID.NavLabel`, which they compile; the app's labels come from
    /// the catalog. In English the two must agree, or every tab tap misses.
    func testTheTabLabelsAreTheOnesTheUITestsTap() {
        XCTAssertEqual(Tab.overview.label, A11yID.NavLabel.overview)
        XCTAssertEqual(Tab.inbox.label, A11yID.NavLabel.inbox)
        XCTAssertEqual(Tab.calls.label, A11yID.NavLabel.calls)
        XCTAssertEqual(Tab.contacts.label, A11yID.NavLabel.contacts)
        XCTAssertEqual(Tab.account.label, A11yID.NavLabel.account)
    }

    /// The generated accessors read the core's language, task-local override included.
    func testTheCopyLocaleIsTheCoresLocale() {
        XCTAssertEqual(L10nRuntime.withLocale(.frCA) { AppL10n.copyLocale }, .frCA)
        XCTAssertEqual(L10nRuntime.withLocale(.en) { AppL10n.copyLocale }, .en)
    }

    // MARK: - Sentences around a name

    /// ⚠️ 3.0.2, AP-024: A WORKSPACE NAME ENDING IN A PERIOD ENDS THE SENTENCE ONCE, in both
    /// languages; any other name keeps the sentence's own full stop.
    func testAWorkspaceNameEndingInAPeriodClosesTheSentenceOnce() {
        let name = "Plomberie Desrosiers-Lanthier inc."
        XCTAssertEqual(AvailabilityCopy.rowSubtitleOnce(name), "Ring my phone for calls in \(name)")
        XCTAssertEqual(
            L10nRuntime.withLocale(.frCA) { AvailabilityCopy.rowSubtitleOnce(name) },
            "Faire sonner mon téléphone pour les appels de l'espace \(name)"
        )
        XCTAssertEqual(AvailabilityCopy.rowSubtitleOnce("Acme"), "Ring my phone for calls in Acme.")
        XCTAssertEqual(AvailabilityCopy.rowSubtitleOnce("Acme..."), "Ring my phone for calls in Acme....")
    }

    /// ⚠️ ONE ELLIPSIS CHARACTER IN FRENCH, ATTACHED TO ITS WORD (3.0.2): « Sonnerie… », never
    /// « Sonnerie... » and never with a space before it. This keeps every French string so.
    func testFrenchUsesTheEllipsisCharacterAttachedToItsWord() throws {
        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // App/Tests
            .deletingLastPathComponent() // App
            .deletingLastPathComponent() // the checkout
            .appendingPathComponent("l10n/ios.toml")
        let french = try CatalogScan.entries(of: catalog).flatMap { entry in entry.french.map { (entry.key, $0) } }
        XCTAssertTrue(french.contains { $0.1 == "Sonnerie\u{2026}" }, "the ring status is the one this guards")
        for (key, text) in french {
            XCTAssertFalse(text.contains("..."), "\(key): three full stops, not U+2026")
            XCTAssertFalse(
                text.contains(" \u{2026}") || text.contains("\u{00A0}\u{2026}"),
                "\(key): a space before U+2026"
            )
        }
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
