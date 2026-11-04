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

    /// ⛔ EVERY TRUNK PREFIX IS libphonenumber's NATIONAL PREFIX (libphonenumber-js 1.13.14), outside
    /// +1, whose `1` the reader handles itself. The non-zero ones are pinned by name; the rest are
    /// ``DialPlan/trunkZero`` or none. The same table is in the other app repos and district-core-rust.
    func testEveryTrunkPrefixIsLibphonenumbersNationalPrefix() {
        let nonZero = ["BY": "8", "HU": "06", "KZ": "8", "MH": "1", "RU": "8", "TM": "8"]
        for country in DialPlan.countries where country.code != "1" {
            let expected = nonZero[country.iso] ?? (DialPlan.trunkZero.contains(country.iso) ? "0" : nil)
            XCTAssertEqual(DialPlan.trunkPrefix(country.iso), expected, country.iso)
        }
        // Its `national_prefix_for_parsing` where that is a plain list of prefixes.
        XCTAssertEqual(DialPlan.parsingTrunkPrefixes, ["BY": ["80", "0"], "GB": ["180020"], "LT": ["8"]])
    }

    func testTheOtherPrefixesLibphonenumberStripsAreStripped() {
        XCTAssertEqual(DialPlan.read("8 612 34567", country: "LT").e164, "+37061234567", "Lithuania's legacy 8")
        XCTAssertEqual(DialPlan.read("0 612 34567", country: "LT").e164, "+37061234567")
        XCTAssertEqual(DialPlan.read("8 029 123 45 67", country: "BY").e164, "+375291234567")
        XCTAssertEqual(DialPlan.read("029 123 45 67", country: "BY").e164, "+375291234567")
        XCTAssertEqual(DialPlan.read("8 12 345678", country: "TM").e164, "+99312345678")
        XCTAssertEqual(DialPlan.read("1 625 1234", country: "MH").e164, "+6926251234")
        XCTAssertEqual(DialPlan.read("180020 20 7946 0958", country: "GB").e164, "+442079460958")
        for (raw, country) in [("8 612 34567", "LT"), ("8 029 123 45 67", "BY"), ("8 12 345678", "TM")] {
            let first = DialPlan.read(raw, country: country)
            XCTAssertEqual(DialPlan.read(first.national, country: country).e164, first.e164, raw)
        }
    }
}
