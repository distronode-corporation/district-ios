@testable import DistrictAI
import DistrictL10n
import XCTest

/// The second round of parity fixes: the carrier balance in French digits, the SIP host
/// kept on one line, and the block confirmation named as Android names it.
final class ParityFixes2Tests: XCTestCase {
    private let nbsp = "\u{00A0}"

    override func tearDown() {
        L10nRuntime.locale = .en
        super.tearDown()
    }

    /// ⛔ « Solde : 12.50 USD » WAS ENGLISH DIGITS AND AN ISO CODE IN A FRENCH SENTENCE. French
    /// goes through the core's money table; English keeps the raw value it always showed.
    func test_PF2_01_theCarrierBalanceIsFrenchMoneyInFrench() {
        L10nRuntime.locale = .frCA
        XCTAssertEqual(
            MarketplaceCopy.carrierBalance("12.50", currency: "USD"),
            "Solde\(nbsp): 12,50\(nbsp)$\(nbsp)US"
        )
        XCTAssertEqual(
            MarketplaceCopy.carrierBalance("1234.5", currency: "cad"),
            "Solde\(nbsp): 1\(nbsp)234,50\(nbsp)$\(nbsp)CA"
        )
        XCTAssertEqual(MarketplaceCopy.carrierBalance("-3.2", currency: nil), "Solde\(nbsp): -3,20")
        XCTAssertEqual(MarketplaceCopy.carrierBalance(" 7 ", currency: "  "), "Solde\(nbsp): 7,00")
        // Not a number: shown as sent, never guessed at.
        XCTAssertEqual(MarketplaceCopy.carrierBalance("n/a", currency: "USD"), "Solde\(nbsp): n/a USD")
        XCTAssertEqual(MarketplaceCopy.carrierBalance("inf", currency: nil), "Solde\(nbsp): inf")
        XCTAssertEqual(MarketplaceCopy.carrierBalance("1e20", currency: nil), "Solde\(nbsp): 1e20")
        // A half-cent rounds up from the decimal string, not from its binary neighbour.
        XCTAssertEqual(MarketplaceCopy.carrierBalance("1.005", currency: nil), "Solde\(nbsp): 1,01")
        XCTAssertEqual(MarketplaceCopy.carrierBalance("-2.675", currency: nil), "Solde\(nbsp): -2,68")
        // A number with something after it is not a balance.
        XCTAssertEqual(MarketplaceCopy.carrierBalance("12 USD", currency: nil), "Solde\(nbsp): 12 USD")
        // Leading zeroes are still a number, and 13 integer digits count in cents past 32 bits.
        XCTAssertEqual(MarketplaceCopy.carrierBalance("00000000000000.50", currency: nil), "Solde\(nbsp): 0,50")
        XCTAssertEqual(
            MarketplaceCopy.carrierBalance("1234567890123.45", currency: nil),
            "Solde\(nbsp): 1\(nbsp)234\(nbsp)567\(nbsp)890\(nbsp)123,45"
        )
        XCTAssertEqual(MarketplaceCopy.carrierBalance("12345678901234", currency: nil), "Solde\(nbsp): 12345678901234")

        L10nRuntime.locale = .en
        XCTAssertEqual(MarketplaceCopy.carrierBalance("12.50", currency: "USD"), "Balance 12.50 USD")
        XCTAssertEqual(MarketplaceCopy.carrierBalance("12.50", currency: nil), "Balance 12.50")
    }

    /// ⛔ A SIP HOST NAME IS ONE IDENTIFIER: the narrow phone broke it at its hyphen. Its row
    /// keeps it on one line and gives up the middle, never the ends.
    func test_PF2_02_theSipHostStaysOnOneLine() throws {
        let carrier = try source("Features/Marketplace/CarrierSection.swift")
        let row = try XCTUnwrap(carrier.components(separatedBy: "label: trunk.domain,").dropFirst().first?.prefix(300))
        XCTAssertTrue(row.contains("identifierLabel: true"), "the SIP host row wraps again")
        let chrome = try source("Features/Settings/SettingsChrome.swift")
        XCTAssertTrue(chrome.contains(".lineLimit(identifierLabel ? 1 : nil)"))
        XCTAssertTrue(chrome.contains(".minimumScaleFactor(identifierLabel ? 0.8 : 1)"))
        XCTAssertTrue(chrome.contains(".truncationMode(.middle)"))
    }

    /// ⛔ ANDROID'S NAME FOR THE SAME BUTTON, VERBATIM, so one test plan addresses both.
    func test_PF2_03_theBlockConfirmationIsNamedAsOnAndroid() {
        XCTAssertEqual(A11yID.Contacts.confirmBlock, "district-contact-block-confirm")
        XCTAssertEqual(A11yID.Contacts.block, "district-contact-block")
        XCTAssertEqual(A11yID.Contacts.unblock, "district-contact-unblock")
    }

    private func source(_ relative: String) throws -> String {
        let file = try SourceScan.sourceRoot().appendingPathComponent(relative)
        return try SourceScan.stripComments(String(contentsOf: file, encoding: .utf8))
    }
}
