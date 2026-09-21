@testable import DistrictCall
import Foundation
import XCTest

/// A Canadian number typed without its country code, as a test.
///
/// ⛔ THIS IS THE CALL THAT REACHES SWITZERLAND. A Canadian number typed as
/// `+4165550123` is dialled as written; Canada is `+1`, so the number should be
/// `+14165550123`, and `+41` is Switzerland. The call connects and is billed.
/// Every assertion below is about the two halves of the guard: the country is
/// DISCLOSED, and only what cannot be E.164 at all is refused. Nothing rewrites
/// the number.
final class DialIncidentTests: XCTestCase {
    func testTheNumberThatReachedSwitzerlandNowSaysSwitzerland() {
        let assessment = DialEntry.assess("+4165550123")
        XCTAssertEqual(DialRegion.named("Switzerland"), assessment.region)
        // ⛔ STILL DIALABLE, AND THAT IS THE DESIGN. `+41 65 550 123` is a
        // well-formed E.164 string; refusing it would mean the client deciding
        // which countries exist. The disclosure is what catches the mistake, in
        // the second before Call is pressed.
        XCTAssertTrue(assessment.isDialable)
    }

    func testTheNumberTheOperatorMeantSaysCanadaAndTheUnitedStates() {
        let assessment = DialEntry.assess("+14165550123")
        XCTAssertEqual(DialRegion.named("Canada and the United States"), assessment.region)
        XCTAssertTrue(assessment.isDialable)
    }

    func testOneDigitOfCountryCodeIsTheWholeDifference() {
        // ⚠️ The two strings differ by a single character and by half the
        // planet. Read together, this is the case for putting a country name on
        // the screen at all.
        XCTAssertNotEqual(DialEntry.assess("+4165550123").region, DialEntry.assess("+14165550123").region)
    }

    func testTheThreeEntriesMeasuredOnTheDeviceNowBehaveAsTheyMust() {
        // The three entries, and what a Dial screen without these rules does:
        //   "12"           → Call DISABLED (correct, and still is)
        //   "4165550123"   → Call ENABLED  (no country code at all)
        //   "+4165550123"  → Call ENABLED  (and dials Switzerland)
        // ⚠️ "12" IS REFUSED FOR THE COUNTRY CODE RATHER THAN FOR ITS LENGTH,
        // and the order is the point: "start with a country code" is the
        // instruction either way, and "too short" would send someone hunting
        // for digits they already have.
        XCTAssertEqual(DialRefusal.missingCountryCode, DialEntry.assess("12").refusal)
        XCTAssertEqual(DialRefusal.missingCountryCode, DialEntry.assess("4165550123").refusal)
        XCTAssertNil(DialEntry.assess("+4165550123").refusal)
    }
}

/// What may be dialled, and what may not.
final class DialRefusalTests: XCTestCase {
    func testAnEntryWithNoPlusNamesNoCountryAndIsRefused() {
        let assessment = DialEntry.assess("4165550123")
        // ⛔ THE ONE UNAMBIGUOUS REFUSAL. Ten digits with no country code is a
        // number the carrier interprets against its own default, and the server
        // adds nothing: `normalizePhoneNumber` strips punctuation and stops.
        XCTAssertEqual(DialRefusal.missingCountryCode, assessment.refusal)
        XCTAssertEqual(DialRegion.none, assessment.region)
        XCTAssertFalse(assessment.isDialable)
    }

    func testNothingTypedIsItsOwnRefusalRatherThanAMissingCountryCode() {
        // ⚠️ The keypad's own hint already says what to type, so the screen must
        // be able to tell "not started" from "started wrong" and stay quiet.
        XCTAssertEqual(DialRefusal.empty, DialEntry.assess("").refusal)
        XCTAssertEqual(DialRefusal.empty, DialEntry.assess("   ").refusal)
        XCTAssertEqual(DialRegion.none, DialEntry.assess("").region)
    }

    func testLettersAlonePresentAsAMissingCountryCode() {
        // ⚠️ Reachable by paste. The compacted form is empty, but the operator
        // typed something, so "start with a country code" is the useful answer
        // and "nothing typed" is not.
        XCTAssertEqual(DialRefusal.missingCountryCode, DialEntry.assess("call me").refusal)
    }

    func testTheEightDigitFloorAndTheFifteenDigitCeilingAreBothEnforced() {
        XCTAssertEqual(DialRefusal.tooShort, DialEntry.assess("+1234567").refusal)
        XCTAssertNil(DialEntry.assess("+12345678").refusal)
        XCTAssertNil(DialEntry.assess("+123456789012345").refusal)
        XCTAssertEqual(DialRefusal.tooLong, DialEntry.assess("+1234567890123456").refusal)
    }

    func testAPlusThatIsNotAtTheFrontIsRefusedRatherThanIgnored() {
        // ⚠️ The server's normalisation keeps a `+` wherever it appears, so this
        // string stays malformed all the way to `E164_RE`. The `.phonePad`
        // keyboard offers `+` on every keypress, which is how it gets typed.
        XCTAssertEqual(DialRefusal.strayPlus, DialEntry.assess("+1416+5550100").refusal)
    }

    func testPunctuationAndSpacingAreToleratedBecauseTheServerStripsThem() {
        // ⛔ THIS IS A PREDICTION, NOT A REWRITE. `normalizePhoneNumber` drops
        // everything but digits and `+`, so the operator's own brackets and
        // spaces reach the route as `+14165550100`. Refusing them here would
        // grey out a button for a number that dials perfectly.
        let assessment = DialEntry.assess("+1 (416) 555-0100")
        XCTAssertNil(assessment.refusal)
        XCTAssertEqual(DialRegion.named("Canada and the United States"), assessment.region)
    }

    func testIsE164AgreesWithTheAssessment() {
        XCTAssertTrue(DialEntry.isE164("+14165550100"))
        XCTAssertFalse(DialEntry.isE164("14165550100"))
        XCTAssertFalse(DialEntry.isE164(""))
    }

    func testNonAsciiDigitsAreNotDigits() {
        // ⚠️ `Character.isNumber` is true for Arabic-Indic digits; `\d` in the
        // server's regex is not. Without the ASCII half the two sides would
        // disagree about what counts as a digit.
        XCTAssertEqual(DialRefusal.missingCountryCode, DialEntry.assess("١٤١٦٥٥٥٠١٠٠").refusal)
    }
}

/// Reading a calling code.
final class CallingCodeTests: XCTestCase {
    func testTheLongestPrefixWins() {
        XCTAssertEqual("Estonia", DialEntry.callingCodeRegion(for: "+3720000100"))
        XCTAssertEqual("Czechia", DialEntry.callingCodeRegion(for: "+420123456789"))
        XCTAssertEqual("Switzerland", DialEntry.callingCodeRegion(for: "+41655501230"))
        XCTAssertEqual("Morocco", DialEntry.callingCodeRegion(for: "+212612345678"))
    }

    func testASingleDigitCodeIsFoundWhenNoLongerOneMatches() {
        // ⚠️ `141` and `14` are unassigned, so the walk falls all the way to `1`.
        XCTAssertEqual("Canada and the United States", DialEntry.callingCodeRegion(for: "+14165550100"))
        XCTAssertEqual("Russia or Kazakhstan", DialEntry.callingCodeRegion(for: "+79123456789"))
    }

    func testAnUnknownCodeIsSaidPlainlyRatherThanGuessedAt() {
        let assessment = DialEntry.assess("+9991234567")
        XCTAssertEqual(DialRegion.unrecognised, assessment.region)
        // ⛔ AND IT STAYS DIALABLE. A table this client happens not to carry is
        // not evidence that a country does not exist.
        XCTAssertTrue(assessment.isDialable)
        XCTAssertNil(DialEntry.callingCodeRegion(for: "+9991234567"))
    }

    func testNoCodeIsReadFromAnEntryWithoutALeadingPlus() {
        XCTAssertNil(DialEntry.callingCodeRegion(for: "4165550123"))
        XCTAssertNil(DialEntry.callingCodeRegion(for: ""))
    }

    func testABarePlusNamesNothingRatherThanReadingAsUnrecognised() {
        // ⚠️ Every entry passes through this state on its way to being typed.
        // "Unrecognised country code" the moment someone taps `+` would be noise.
        XCTAssertEqual(DialRegion.none, DialEntry.assess("+").region)
    }

    func testTheCountryIsDisclosedBeforeTheNumberIsLongEnoughToDial() {
        // ⛔ THE DISCLOSURE IS WORTH MOST EARLY. A wrong country code is visible
        // three characters in, and by the time the number is dialable the
        // operator has stopped looking at its front.
        let assessment = DialEntry.assess("+4166")
        XCTAssertEqual(DialRegion.named("Switzerland"), assessment.region)
        XCTAssertEqual(DialRefusal.tooShort, assessment.refusal)
    }

    func testEveryTableKeyIsOneToThreeAsciiDigits() {
        for code in DialEntry.callingCodes.keys {
            XCTAssertFalse(code.isEmpty, "empty calling code key")
            XCTAssertLessThanOrEqual(code.count, DialEntry.maximumCallingCodeDigits, "calling code too long: \(code)")
            XCTAssertTrue(code.allSatisfy { $0.isASCII && $0.isNumber }, "non-digit calling code: \(code)")
        }
    }

    func testNoCallingCodeIsAPrefixOfAnother() {
        // ⛔ THE PROPERTY THE LONGEST-PREFIX WALK DEPENDS ON. If `35` were ever
        // added beside `353`, an Irish number would keep resolving to Ireland
        // and a `+35…` from anywhere else would silently take the shorter
        // entry's name. That failure is invisible on the screen, which is why it
        // is asserted here rather than trusted.
        let codes = Set(DialEntry.callingCodes.keys)
        for code in codes {
            for length in 1 ..< code.count {
                let shorter = String(code.prefix(length))
                XCTAssertFalse(codes.contains(shorter), "\(shorter) is a prefix of \(code)")
            }
        }
    }
}

/// The call-back list hands the keypad a number the SERVER produced.
///
/// ⛔ IF THIS VALIDATION REJECTED THOSE ROWS THE FEATURE WOULD BE DEAD, and it
/// would be dead quietly: the tap still fills the field, the button just never
/// enables. The numbers are read out of the committed contract fixture rather
/// than typed here, so a change to the server's shape fails this test instead of
/// reaching the handset.
final class CallbackNumberTests: XCTestCase {
    func testEveryCallbackNumberInTheContractFixtureIsDialable() throws {
        let numbers = try callbackNumbers()
        XCTAssertFalse(numbers.isEmpty, "district-calls.json carried no `from` values")
        for number in numbers {
            let assessment = DialEntry.assess(number)
            XCTAssertTrue(assessment.isDialable, "\(number) would not dial: \(String(describing: assessment.refusal))")
            XCTAssertEqual(DialRegion.named("Canada and the United States"), assessment.region, "\(number)")
        }
    }

    /// Every non-null `from` in the calls fixture.
    ///
    /// ⚠️ A MISSING FILE THROWS ``FixtureNotFound``, which names the path the
    /// lookup used and the override, rather than Foundation's read error.
    private func callbackNumbers() throws -> [String] {
        let url = Self.contractsDirectory.appendingPathComponent("district-calls.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FixtureNotFound(path: url.path)
        }
        let data = try Data(contentsOf: url)
        let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        return (rows ?? []).compactMap { $0["from"] as? String }
    }

    /// `<repo>/contracts`, walked up from this source file.
    ///
    /// ⚠️ FIVE COMPONENTS, INNERMOST FIRST: this file, `DistrictCallTests`,
    /// `Tests`, `DistrictCore`, `Packages`, which leaves the repository root. It
    /// mirrors `ContractFixtures.defaultDirectory` rather than importing it,
    /// because depending on `ContractGateSupport` from this target would be a
    /// `Package.swift` change for one path.
    ///
    /// ⚠️ THE SAME `DISTRICT_CONTRACTS_DIR` OVERRIDE, for containerised runs
    /// where the repo root is not mounted. A blank value counts as unset:
    /// `URL(fileURLWithPath: "")` resolves to the working directory.
    private static var contractsDirectory: URL {
        let override = ProcessInfo.processInfo.environment[FixtureNotFound.overrideKey] ?? ""
        if !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 5 {
            url = url.deletingLastPathComponent()
        }
        return url.appendingPathComponent("contracts", isDirectory: true)
    }
}

/// The calls fixture was not where the lookup went, and where that was.
private struct FixtureNotFound: Error, CustomStringConvertible {
    static let overrideKey = "DISTRICT_CONTRACTS_DIR"

    let path: String

    var description: String {
        """
        contract fixture NOT FOUND at \(path).
          The fixtures live in contracts/ at the repository root, found by walking
          up from #filePath, unless \(Self.overrideKey) names another directory.
          If it is set, that directory lacks this file; unset it or point it at a
          copy of contracts/. If it is unset, the walk no longer lands on the
          repository root (a test directory moved), or this is a partial checkout.
        """
    }
}
