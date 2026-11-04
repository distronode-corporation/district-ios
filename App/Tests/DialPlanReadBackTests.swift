@testable import DistrictAI
import XCTest

/// Three readings Seer found in district-core-rust #63's port of this file, checked here.
///
/// ⛔ WHAT THE FIELD SHOWS IS READ AGAIN ON THE NEXT EDIT, so it must read back to the number it
/// came from: `+1 1 416 555 0199` pasted was shown as `(141) 655-50199`, and reading that again
/// took its leading `1` as the trunk prefix, a whole Canadian number with Call on.
///
/// ⛔ EVERY COUNTRY WHOSE NUMBERS CARRY A TRUNK `0` DROPS IT: `0412 123 4567` typed in Venezuela
/// sent `+58 0412…`, a number that does not exist. The list is libphonenumber's national prefix `0`.
final class DialPlanReadBackTests: XCTestCase {
    func testAPastedPlusOneOneKeepsItsInternationalForm() {
        let pasted = DialPlan.read("+1 1 416 555 0199", country: "CA")
        XCTAssertEqual(pasted.status, .tooLong)
        XCTAssertNil(pasted.e164)
        XCTAssertEqual(pasted.national, "+114165550199")
        let again = DialPlan.read(pasted.national, country: pasted.iso)
        XCTAssertEqual(again.status, .tooLong)
        XCTAssertNil(again.e164, "never a callable Canadian number")
        XCTAssertEqual(again.national, pasted.national)
    }

    func testEveryOrdinaryReadingReadsBackAlike() {
        let cases: [(String, String?)] = [
            ("4165550199", "CA"), ("020 7946 0958", "GB"), ("8 495 123 4567", "RU"), ("1300 123 456", "AU"),
            ("06 1 234 5678", "HU"), ("+1 800 555 0100", "CA"), ("+7 701 123 4567", nil), ("0412 123 4567", "VE"),
            ("+44", nil), ("1", "CA"),
        ]
        for (raw, country) in cases {
            let first = DialPlan.read(raw, country: country)
            let second = DialPlan.read(first.national, country: first.iso ?? country)
            XCTAssertEqual(second.e164, first.e164, "\(raw) in \(country ?? "none")")
            XCTAssertEqual(second.national, first.national, "\(raw) in \(country ?? "none")")
        }
    }

    func testEveryTrunkZeroCountryLibphonenumberNamesIsListed() {
        // libphonenumber-js 1.13.14 metadata: every country of ``DialPlan/countries`` whose national
        // prefix is `0`. The same list is in district-macos, district-android and district-core-rust.
        let expected: Set = [
            "AE", "AF", "AL", "AM", "AR", "AT", "AU", "AZ", "BA", "BD", "BE", "BG", "BO", "BR", "CD", "CH",
            "CN", "CO", "CU", "DE", "DZ", "EC", "EG", "ER", "ET", "FI", "FR", "GB", "GE", "GF", "GH", "GP",
            "HR", "ID", "IE", "IL", "IN", "IQ", "IR", "JO", "JP", "KE", "KG", "KH", "KI", "KP", "KR", "LA",
            "LB", "LI", "LK", "LR", "LT", "LY", "MA", "MC", "MD", "ME", "MG", "MK", "MM", "MN", "MQ", "MW",
            "MY", "NA", "NG", "NL", "NP", "NZ", "PE", "PH", "PK", "PM", "PS", "PY", "RE", "RO", "RS", "RW",
            "SA", "SD", "SE", "SI", "SK", "SL", "SO", "SS", "SY", "TH", "TR", "TW", "TZ", "UA", "UG", "UY",
            "VE", "VN", "XK", "YE", "ZA", "ZM", "ZW",
        ]
        XCTAssertEqual(DialPlan.trunkZero, expected)
    }

    func testVenezuelaEcuadorAndUruguayDropTheirTrunkZero() {
        XCTAssertEqual(DialPlan.read("0412 123 4567", country: "VE").e164, "+584121234567")
        XCTAssertEqual(DialPlan.read("+58 0412 123 4567", country: nil).e164, "+584121234567")
        XCTAssertEqual(DialPlan.read("099 123 4567", country: "EC").e164, "+593991234567")
        XCTAssertEqual(DialPlan.read("099 123 456", country: "UY").e164, "+59899123456")
        XCTAssertEqual(DialPlan.read("0412 123 4567", country: "VE").national, "0412 123 4567")
    }
}
