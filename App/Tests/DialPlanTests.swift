@testable import DistrictAI
import DistrictL10n
import Foundation
import XCTest

/// Dialler design A's number reading: the country on the button, the local form in the
/// field, and the E.164 number that is sent.
///
/// ⛔ THE SWITZERLAND CASE IS HERE BECAUSE IT WAS A BILLED CALL. A Canadian mobile typed as
/// `+4165550123` is `+41`, Switzerland; the flag has to move there, and nothing may be sent
/// until the line under the field states the whole number.
///
/// ⚠️ `@MainActor` ONLY FOR THE COPY HELPERS, which are `static` members of the main-actor
/// ``DialerModel``; ``DialPlan`` itself is nonisolated.
@MainActor
final class DialPlanTests: XCTestCase {
    // MARK: - Local numbers

    func testACanadianNumberTypedLocallyFormatsAndDialsAsE164() {
        let reading = DialPlan.read("4165550199", country: "CA")
        XCTAssertEqual(reading.status, .ready)
        XCTAssertEqual(reading.iso, "CA")
        XCTAssertEqual(reading.national, "(416) 555-0199")
        XCTAssertEqual(reading.international, "+1 416 555 0199")
        XCTAssertEqual(reading.e164, "+14165550199")
    }

    /// ⚠️ THE FIELD REWRITES ITSELF AS DIGITS ARRIVE, so each partial form must read back
    /// to the same digits, or a keystroke would be lost.
    func testFormattingAsYouTypeKeepsEveryDigit() {
        var field = ""
        for digit in "4165550199" {
            field = DialPlan.read(field + String(digit), country: "CA").national
        }
        XCTAssertEqual(field, "(416) 555-0199")
        XCTAssertEqual(DialPlan.read("416", country: "CA").national, "416")
        XCTAssertEqual(DialPlan.read("4165", country: "CA").national, "(416) 5")
        XCTAssertEqual(DialPlan.read("4165550", country: "CA").national, "(416) 555-0")
    }

    func testANumberStillBeingTypedIsNotDialable() {
        let reading = DialPlan.read("416555", country: "CA")
        XCTAssertEqual(reading.status, .typing)
        XCTAssertNil(reading.e164)
    }

    func testTheNorthAmericanTrunkOneIsDropped() {
        let reading = DialPlan.read("1 416 555 0199", country: "CA")
        XCTAssertEqual(reading.e164, "+14165550199")
        XCTAssertEqual(reading.national, "(416) 555-0199")
    }

    /// ⚠️ A +1 NUMBER IS READ BY ITS AREA CODE, so a Seattle number typed under the Canadian
    /// flag says it rings the United States.
    func testAPlusOneAreaCodeFlipsCanadaAndTheUnitedStates() {
        XCTAssertEqual(DialPlan.read("2065550142", country: "CA").iso, "US")
        XCTAssertEqual(DialPlan.read("4165550199", country: "US").iso, "CA")
        XCTAssertEqual(DialPlan.read("8765550100", country: "US").iso, "JM", "a Jamaican number is not the US")
    }

    func testALondonNumberTypedLocallyDropsItsTrunkZero() {
        let reading = DialPlan.read("020 7946 0958", country: "GB")
        XCTAssertEqual(reading.status, .ready)
        XCTAssertEqual(reading.national, "020 7946 0958")
        XCTAssertEqual(reading.e164, "+442079460958")
    }

    func testTooManyDigitsIsRefused() {
        let reading = DialPlan.read("41655501990", country: "CA")
        XCTAssertEqual(reading.status, .tooLong)
        XCTAssertNil(reading.e164)
    }

    /// ⚠️ EVERY NUMBER A COUNTRY ISSUES MUST BE DIALABLE, not only its common shape (Seer on
    /// PR #95): Australia's 13 and 1300/1800 numbers, Singapore's 1800 toll-free numbers and
    /// a short UK freephone number.
    func testNonGeographicNumbersAreDialable() {
        let australia = DialPlan.read("1300 123 456", country: "AU")
        XCTAssertEqual(australia.national, "1300 123 456", "no trunk 0 and no parentheses")
        XCTAssertEqual(australia.e164, "+611300123456")
        XCTAssertEqual(DialPlan.read("13 12 34", country: "AU").e164, "+61131234")
        XCTAssertEqual(DialPlan.read("1800 123 4567", country: "SG").e164, "+6518001234567")
        XCTAssertEqual(DialPlan.read("0800 1111", country: "GB").e164, "+448001111")
        XCTAssertEqual(DialPlan.read("02 1234 5678", country: "AU").national, "(02) 1234 5678")
    }

    /// ⛔ BACKSPACE ALWAYS REMOVES A DIGIT. The field formats after every edit, so a format
    /// that ended in punctuation (Australia's `(02)`, Seer on PR #95) would put the deleted
    /// character straight back and the operator could never delete past it.
    func testDeletingTheLastCharacterAlwaysRemovesADigit() {
        let numbers: [(String, String)] = [
            ("CA", "4165550199"), ("GB", "02079460958"), ("FR", "0639980123"), ("DE", "030123456"),
            ("AU", "0212345678"), ("AU", "0491570156"), ("AU", "1300123456"), ("CH", "0441234567"),
            ("SG", "61234567"), ("IT", "0612345678"), ("JP", "0312345678"), ("RU", "84951234567"),
            ("HU", "0612345678"),
        ]
        for (country, digits) in numbers {
            var field = ""
            for digit in digits {
                field = DialPlan.read(field + String(digit), country: country).national
                guard let last = field.last else { continue }
                XCTAssertTrue(last.isNumber, "\(country): \"\(field)\" ends in punctuation")
                let before = field.filter(\.isNumber).count
                let after = DialPlan.read(String(field.dropLast()), country: country).national
                XCTAssertLessThan(after.filter(\.isNumber).count, before, "\(country): backspace on \"\(field)\"")
            }
        }
    }

    /// ⛔ A TRUNK PREFIX THAT IS NOT `0` IS DROPPED TOO (Seer on PR #95): kept, `8 495…` in
    /// Russia would send `+7 849…`, a wrong number that still dials.
    func testTrunkPrefixesOtherThanZeroAreDropped() {
        let moscow = DialPlan.read("8 495 123 4567", country: "RU")
        XCTAssertEqual(moscow.e164, "+74951234567")
        XCTAssertEqual(moscow.national, "8495 123 4567")
        XCTAssertEqual(DialPlan.read("06 1 234 5678", country: "HU").e164, "+3612345678")
        XCTAssertEqual(DialPlan.read("0", country: "HU").national, "0", "half of 06 is shown as typed")
        XCTAssertEqual(DialPlan.read("8 017 123 4567", country: "BY").e164, "+375171234567")
    }

    /// ⚠️ A +1 TOLL-FREE NUMBER NAMES NO COUNTRY, so the +1 country on screen stays.
    func testNorthAmericanTollFreeKeepsTheCountryOnScreen() {
        XCTAssertEqual(DialPlan.read("8005550100", country: "CA").iso, "CA")
        XCTAssertEqual(DialPlan.read("+1 888 555 0100", country: "CA").iso, "CA")
        XCTAssertEqual(DialPlan.read("+1 888 555 0100", country: nil).iso, "US")
    }

    // MARK: - Numbers that name their own country

    func testAPastedPlusFortyFourNumberMovesToTheUnitedKingdom() {
        let reading = DialPlan.read("+44 20 7946 0958", country: "CA")
        XCTAssertEqual(reading.iso, "GB")
        XCTAssertEqual(reading.status, .ready)
        XCTAssertEqual(reading.national, "020 7946 0958")
        XCTAssertEqual(reading.international, "+44 20 7946 0958")
        XCTAssertEqual(reading.e164, "+442079460958")
    }

    /// ⚠️ "+44 (0)20 …" IS HOW A SIGNATURE WRITES IT; the 0 is not dialled after the code.
    func testASignatureStyleTrunkZeroAfterTheCodeIsDropped() {
        XCTAssertEqual(DialPlan.read("+44 (0)20 7946 0958", country: nil).e164, "+442079460958")
    }

    /// ⛔ THE BILLED CALL. `+41` is Switzerland whatever the workspace's country, and the
    /// flag moves there; with eight digits after the code it is not even a whole Swiss
    /// number, so nothing can be sent.
    func testTheSwitzerlandMisdialMovesTheFlagAndSendsNothing() {
        let reading = DialPlan.read("+4165550123", country: "CA")
        XCTAssertEqual(reading.iso, "CH")
        XCTAssertEqual(reading.callingCode, "41")
        XCTAssertEqual(reading.nationalNumber, "65550123")
        XCTAssertEqual(reading.status, .typing)
        XCTAssertNil(reading.e164)
        XCTAssertNil(DialerModel.destinationLine(reading), "no Rings line for a number that cannot be sent")
    }

    func testTheNorthAmericanExitCodeStandsForPlus() {
        let reading = DialPlan.read("011 44 20 7946 0958", country: "CA")
        XCTAssertEqual(reading.iso, "GB")
        XCTAssertEqual(reading.e164, "+442079460958")
    }

    func testTheInternationalZeroZeroStandsForPlusOutsideNorthAmerica() {
        XCTAssertEqual(DialPlan.read("0033 6 39 98 01 23", country: "GB").e164, "+33639980123")
        XCTAssertEqual(DialPlan.read("0033639980123", country: "FR").iso, "FR")
    }

    /// ⚠️ UNDER A +1 FLAG `00` IS NOT AN EXIT CODE, so it is read as a (short) local number.
    func testZeroZeroIsNotAnExitCodeUnderAPlusOneFlag() {
        XCTAssertNotEqual(DialPlan.read("0044 20 7946 0958", country: "CA").e164, "+442079460958")
    }

    func testPlusSevenIsKazakhstanForASixOrSevenAndRussiaOtherwise() {
        XCTAssertEqual(DialPlan.read("+7 701 234 5678", country: nil).iso, "KZ")
        XCTAssertEqual(DialPlan.read("+7 495 123 4567", country: nil).iso, "RU")
    }

    /// ⚠️ AN UNKNOWN CODE IS NAMED AS UNKNOWN AND STAYS DIALABLE, the rule the core's
    /// ``DialRegion/unrecognised`` set before this design.
    /// ⛔ TYPED ONE KEY AT A TIME, +7 701 … IS KAZAKHSTAN TOO (Seer on district-macos #91). `+7`
    /// moves the flag to Russia and the field drops to the local form, so the rest arrives as
    /// a national number under Russia; it must be read again by its first digit, as a paste is.
    func test_IOS_DIALER_09_plusSevenTypedKeyByKeyReachesKazakhstan() {
        var field = ""
        var country: String? = "CA"
        for key in "+77012345678" {
            let reading = DialPlan.read(field + String(key), country: country)
            country = reading.iso ?? country
            field = reading.national
        }
        let typed = DialPlan.read(field, country: country)
        XCTAssertEqual(typed.iso, "KZ")
        XCTAssertEqual(typed.e164, "+77012345678")
        let pasted = DialPlan.read("+7 701 234 5678", country: "CA")
        XCTAssertEqual(typed.iso, pasted.iso, "typed and pasted read alike")
        XCTAssertEqual(typed.national, pasted.national)
        // And back: a Moscow number under the Kazakh flag rings Russia.
        XCTAssertEqual(DialPlan.read("84951234567", country: "KZ").iso, "RU")
        XCTAssertEqual(DialPlan.read("87012345678", country: "RU").iso, "KZ")
        // ⚠️ Before the deciding digit, the +7 country on screen stays.
        XCTAssertEqual(DialPlan.read("8", country: "KZ").iso, "KZ")
        XCTAssertEqual(DialPlan.read("8", country: "RU").iso, "RU")
        XCTAssertEqual(DialPlan.read("+7", country: "KZ").iso, "KZ")
        XCTAssertEqual(DialPlan.read("+7", country: "CA").iso, "RU")
    }

    /// ⚠️ THE SAME FOR +1, which already re-read its area code: typed key by key from a
    /// non-+1 flag, `+1 416 …` ends on Canada and `+1 876 …` on Jamaica.
    func test_IOS_DIALER_10_plusOneTypedKeyByKeyFollowsTheAreaCode() {
        for (keys, iso) in [("+14165550199", "CA"), ("+18765550199", "JM"), ("+12065550199", "US")] {
            var field = ""
            var country: String? = "GB"
            for key in keys {
                let reading = DialPlan.read(field + String(key), country: country)
                country = reading.iso ?? country
                field = reading.national
            }
            XCTAssertEqual(DialPlan.read(field, country: country).iso, iso, keys)
        }
    }

    func testAnUnknownCodeStaysDialableWithoutAName() {
        let reading = DialPlan.read("+999 1234 5678", country: "CA")
        XCTAssertNil(reading.iso)
        XCTAssertEqual(reading.status, .ready)
        XCTAssertEqual(reading.e164, "+99912345678")
        XCTAssertEqual(DialerModel.destinationLine(reading), DialerModel.destinationUnrecognised)
    }

    func testAPlusAloneIsStillBeingTyped() {
        let reading = DialPlan.read("+", country: "CA")
        XCTAssertEqual(reading.status, .typing)
        XCTAssertEqual(reading.national, "+")
    }

    // MARK: - Emergency numbers

    /// ⛔ REFUSED IN EVERY COUNTRY AND WITH NONE, and before anything asks for a country.
    func testEmergencyNumbersAreRefusedWhateverTheCountry() {
        for (number, country) in [
            ("911", "CA"),
            ("911", nil),
            ("112", "FR"),
            ("999", "GB"),
            ("000", "AU"),
            ("1911", "US"),
        ] {
            let reading = DialPlan.read(number, country: country)
            XCTAssertEqual(reading.status, .emergency, "\(number) in \(country ?? "no country")")
            XCTAssertNil(reading.e164)
        }
    }

    /// ⚠️ WHOLE NUMBERS ONLY: a North American number beginning 911 is ordinary.
    func testANumberThatStartsWithAnEmergencyCodeIsOrdinary() {
        XCTAssertEqual(DialPlan.read("+1 911 555 0100", country: nil).status, .ready)
    }

    // MARK: - No home country

    func testDigitsWithNoCountryAskForOne() {
        let reading = DialPlan.read("4165550199", country: nil)
        XCTAssertEqual(reading.status, .needsCountry)
        XCTAssertNil(reading.e164)
        XCTAssertNil(reading.iso)
    }

    func testAPlusNumberWorksWithNoCountry() {
        let reading = DialPlan.read("+33 6 39 98 01 23", country: nil)
        XCTAssertEqual(reading.iso, "FR")
        XCTAssertEqual(reading.national, "06 39 98 01 23")
        XCTAssertEqual(reading.e164, "+33639980123")
    }

    func testEmptyIsEmpty() {
        XCTAssertEqual(DialPlan.read("", country: "CA").status, .empty)
        XCTAssertEqual(DialPlan.read("", country: nil).status, .empty)
    }

    // MARK: - Countries

    func testFlagsAreRegionalIndicatorPairs() {
        XCTAssertEqual(DialPlan.flag("CA"), "\u{1F1E8}\u{1F1E6}")
        XCTAssertEqual(DialPlan.flag("DE"), "\u{1F1E9}\u{1F1EA}")
    }

    func testEveryCountryHasAFlagACodeAndAName() {
        XCTAssertGreaterThan(DialPlan.countries.count, 200)
        XCTAssertEqual(Set(DialPlan.countries.map(\.iso)).count, DialPlan.countries.count, "a country listed twice")
        for country in DialPlan.countries {
            XCTAssertEqual(country.iso.count, 2)
            XCTAssertTrue(country.code.allSatisfy(\.isNumber), country.iso)
            XCTAssertNotEqual(DialPlan.name(country.iso, locale: .en), country.iso, "no name for \(country.iso)")
        }
    }

    /// ⚠️ CALLING CODES ARE PREFIX-FREE, which the longest-match reading relies on.
    func testNoCallingCodeIsAPrefixOfAnother() {
        let codes = Set(DialPlan.countries.map(\.code))
        for code in codes {
            for other in codes where other != code {
                XCTAssertFalse(other.hasPrefix(code), "+\(code) shadows +\(other)")
            }
        }
    }

    func testEveryCountryReadsBackToItselfOrItsCodesFirstCountry() {
        for country in DialPlan.countries where country.code != "1" && country.code != "7" {
            let iso = DialPlan.read("+" + country.code + "12345678", country: nil).iso
            XCTAssertEqual(DialPlan.callingCode(for: iso ?? ""), country.code, country.iso)
        }
    }

    func testSearchFindsByNameCodeAndCallingCode() {
        XCTAssertEqual(DialPlan.search("germ", locale: .en), ["DE"])
        XCTAssertEqual(DialPlan.search("allem", locale: .frCA), ["DE"])
        XCTAssertTrue(DialPlan.search("+49", locale: .en).contains("DE"))
        XCTAssertTrue(DialPlan.search("de", locale: .en).contains("DE"))
        XCTAssertTrue(DialPlan.search("quebec zzz", locale: .en).isEmpty)
    }

    /// ⚠️ ACCENTS ARE IGNORED, so "etats" finds the United States in French.
    /// ⛔ RANKED, BECAUSE RETURN PICKS THE FIRST ROW (Seer on district-macos #91): `us` listed
    /// Australia and Austria before the United States.
    func test_IOS_DIALER_11_searchRanksCodeThenNameStartThenCallingCodeThenContains() {
        let us = DialPlan.search("us", locale: .en)
        XCTAssertEqual(us.first, "US")
        XCTAssertLessThan(try XCTUnwrap(us.firstIndex(of: "US")), try XCTUnwrap(us.firstIndex(of: "AU")))
        XCTAssertEqual(DialPlan.search("ca", locale: .en).first, "CA")
        // A name that starts with the query beats one that only contains it.
        let can = DialPlan.search("can", locale: .en)
        XCTAssertEqual(can.first, "CA")
        let ger = DialPlan.search("ger", locale: .en)
        XCTAssertLessThan(try XCTUnwrap(ger.firstIndex(of: "DE")), try XCTUnwrap(ger.firstIndex(of: "DZ")))
        // The countries sharing a calling code stay alphabetical among themselves.
        let plusOne = DialPlan.search("+1", locale: .en)
        XCTAssertTrue(plusOne.contains("CA") && plusOne.contains("US"))
        XCTAssertEqual(plusOne, DialPlan.sortedCountries(locale: .en).filter(plusOne.contains))
        // An exact ISO code first, then names starting with it: "de" is Germany, then Denmark.
        let de = DialPlan.search("de", locale: .en)
        XCTAssertEqual(de.first, "DE")
        XCTAssertEqual(de.dropFirst().first, "DK")
    }

    func testSearchIgnoresAccentsAndCase() {
        XCTAssertTrue(DialPlan.search("ETATS-UNIS", locale: .frCA).contains("US"))
    }

    func testTheListIsAlphabeticalInTheAppsLanguage() {
        let english = DialPlan.sortedCountries(locale: .en)
        XCTAssertEqual(english.first, "AF")
        let french = DialPlan.sortedCountries(locale: .frCA)
        XCTAssertLessThan(
            try XCTUnwrap(french.firstIndex(of: "DE")),
            try XCTUnwrap(french.firstIndex(of: "AD")),
            "Allemagne sorts before Andorre in French"
        )
    }

    func testSuggestedIsHomeThenCurrentThenCanadaAndTheUnitedStatesOnce() {
        XCTAssertEqual(DialPlan.suggested(home: "FR", current: "GB"), ["FR", "GB", "CA", "US"])
        XCTAssertEqual(DialPlan.suggested(home: "CA", current: "CA"), ["CA", "US"])
        XCTAssertEqual(DialPlan.suggested(home: nil, current: nil), ["CA", "US"])
    }

    // MARK: - The home country

    func testTheHomeCountryIsWhereMostOfTheNumbersAre() {
        XCTAssertEqual(DialerModel.homeCountry(fromNumbers: ["+14165550100", "+12065550100", "+16475550100"]), "CA")
        XCTAssertEqual(
            DialerModel.homeCountry(fromNumbers: ["+442079460100", "+14165550100"]),
            "GB",
            "a tie goes first"
        )
        XCTAssertNil(DialerModel.homeCountry(fromNumbers: []))
        XCTAssertNil(DialerModel.homeCountry(fromNumbers: ["not a number"]))
        // ⚠️ TOLL-FREE NUMBERS DO NOT VOTE (Seer on PR #95).
        XCTAssertEqual(
            DialerModel.homeCountry(fromNumbers: ["+18005550100", "+18885550100", "+14165550100"]),
            "CA"
        )
        XCTAssertNil(DialerModel.homeCountry(fromNumbers: ["+18005550100"]))
    }
}
