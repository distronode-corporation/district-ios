@testable import DistrictAI
import DistrictL10n
import XCTest

/// The line under the dialler's field: where the call rings and the number that is sent.
///
/// ⚠️ THE READING IS ``DialPlan``'S AND `DialPlanTests` PINS IT. What is pinned here is the
/// WORDING, the sentence that lets an operator notice `+41` is Switzerland before Call.
/// ⚠️ `@MainActor` BECAUSE THE COPY HANGS OFF ``DialerModel``, WHICH IS. These are
/// pure functions, but they are `static` members of a MainActor-isolated type, so
/// reaching them from a nonisolated test is a concurrency error rather than a
/// lookup failure — and the compiler words it as neither.
@MainActor
final class DialerDestinationLineTests: XCTestCase {
    /// ⚠️ nil RATHER THAN AN EMPTY STRING while the number is incomplete: the flag already
    /// names the country, and an empty string would reserve space for nothing.
    func testAnIncompleteNumberSaysNothing() {
        XCTAssertNil(DialerModel.destinationLine(DialPlan.read("416555", country: "CA")))
        XCTAssertNil(DialerModel.destinationLine(DialPlan.read("", country: "CA")))
    }

    /// ⛔ AN UNKNOWN CODE SAYS SO PLAINLY RATHER THAN GUESSING. Naming the wrong
    /// country is worse than naming none, because a wrong name is read as
    /// confirmation of a number that is about to be dialled.
    func testUnrecognisedCodeIsAdmittedRatherThanGuessed() {
        XCTAssertEqual(
            DialerModel.destinationLine(DialPlan.read("+999 1234 5678", country: nil)),
            "Unrecognised country code. Check the number before calling."
        )
        XCTAssertEqual(
            DialerModel.destinationLine(DialPlan.read("+9991", country: nil)),
            "Unrecognised country code. Check the number before calling.",
            "said as soon as three digits name no country"
        )
    }

    /// ⛔ THE SENTENCE THAT WOULD HAVE CAUGHT THE BILLED CALL: the country and the whole
    /// number, which is exactly what is sent.
    func testACompleteNumberSaysWhereItRingsAndTheWholeNumber() {
        XCTAssertEqual(
            DialerModel.destinationLine(DialPlan.read("4165550199", country: "CA")),
            "Rings Canada · +1 416 555 0199"
        )
        XCTAssertEqual(
            DialerModel.destinationLine(DialPlan.read("+41 65 550 12 34", country: "CA")),
            "Rings Switzerland · +41 65 550 12 34"
        )
    }

    func testTheFrenchLineNamesTheCountryInFrench() {
        L10nRuntime.withLocale(.frCA) {
            XCTAssertEqual(
                DialerModel.destinationLine(DialPlan.read("+44 20 7946 0958", country: nil)),
                "Pays de destination\u{00A0}: Royaume-Uni · +44 20 7946 0958"
            )
        }
    }

    func testTheEmptyFieldSaysHowToType() {
        XCTAssertEqual(DialerModel.entryHint(country: "CA"), "Type the number as you would dial it in Canada.")
        XCTAssertEqual(DialerModel.entryHint(country: nil), "Start with + and the country code, or pick a country.")
    }

    func testDigitsWithNoCountryAskForOne() {
        XCTAssertEqual(
            DialerModel.entryProblem(.needsCountry),
            "Pick a country, or start with + and the country code."
        )
        XCTAssertNotNil(DialerModel.entryProblem(.tooLong))
        for quiet: DialPlan.Status in [.empty, .typing, .ready] {
            XCTAssertNil(DialerModel.entryProblem(quiet))
        }
    }
}

/// The App-target half of the emergency hand-off: the sentence itself.
///
/// ⛔ `DialEntry` (the core) DECIDES, THIS SAYS IT. The detection is pinned on the cheap
/// Linux runner by `EmergencyNumberTests` and its use here by `DialPlanTests`; what is
/// pinned here is whether the copy names the Phone app, which is the half that makes it a
/// hand-off rather than a refusal.
@MainActor
final class EmergencyCopyTests: XCTestCase {
    func testTheEmergencyLineNamesThePhoneApp() {
        let line = DialerModel.entryProblem(.emergency)
        XCTAssertNotNil(line)
        XCTAssertTrue(line?.contains("Phone app") == true, "a bare refusal strands the caller")
    }

    /// ⛔ IT MUST NOT READ AS A CORRECTABLE MISTAKE. Telling somebody dialling an
    /// emergency number to add a country code is the failure this pins.
    func testTheEmergencyLineNeverAsksForACountryCode() {
        let line = DialerModel.entryProblem(.emergency) ?? ""
        XCTAssertFalse(line.lowercased().contains("country code"))
        XCTAssertFalse(line.lowercased().contains("too short"))
    }

    func testItIsDistinctFromEveryOtherRefusal() {
        let emergency = DialerModel.entryProblem(.emergency)
        for other: DialPlan.Status in [.needsCountry, .tooLong] {
            XCTAssertNotEqual(DialerModel.entryProblem(other), emergency)
        }
    }
}
