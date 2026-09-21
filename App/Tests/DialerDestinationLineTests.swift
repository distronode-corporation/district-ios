@testable import DistrictAI
import DistrictCall
import XCTest

/// The App-target half of the dialler's number handling.
///
/// ⚠️ THE VALIDATION HALF IS NOT HERE AND SHOULD NOT BE. `DialEntry.assess(_:)`
/// decides what is dialable and lives in `Packages/DistrictCore`, where
/// `DialNumberTests` already covers it on the cheap Linux runner. What only the
/// App target can reach is the WORDING — the sentence beside the field that lets
/// an operator notice `+41` is Switzerland before pressing Call.
/// ⚠️ `@MainActor` BECAUSE THE COPY HANGS OFF ``DialerModel``, WHICH IS. These are
/// pure functions, but they are `static` members of a MainActor-isolated type, so
/// reaching them from a nonisolated test is a concurrency error rather than a
/// lookup failure — and the compiler words it as neither.
@MainActor
final class DialerDestinationLineTests: XCTestCase {
    /// ⚠️ nil RATHER THAN AN EMPTY STRING. Nothing has been typed that names a
    /// country, so there is nothing honest to say yet and `entryHint` occupies
    /// that moment instead; an empty string would render a blank line and reserve
    /// space for a sentence that never arrives.
    func testNoCountryCodeSaysNothing() {
        XCTAssertNil(DialerModel.destinationLine(.none))
    }

    /// ⛔ AN UNKNOWN CODE SAYS SO PLAINLY RATHER THAN GUESSING. Naming the wrong
    /// country is worse than naming none, because a wrong name is read as
    /// confirmation of a number that is about to be dialled.
    func testUnrecognisedCodeIsAdmittedRatherThanGuessed() {
        XCTAssertEqual(
            DialerModel.destinationLine(.unrecognised),
            "Unrecognised country code. Check the number before calling."
        )
    }

    /// ⛔ THE SENTENCE THAT WOULD HAVE CAUGHT THE BILLED CALL. `+41` resolves to
    /// Switzerland, and this line is the only place in the app or on the server
    /// that ever mentions a country.
    func testNamedCountryIsStatedBesideTheField() {
        XCTAssertEqual(DialerModel.destinationLine(.named("Switzerland")), "This number rings Switzerland.")
        XCTAssertEqual(DialerModel.destinationLine(.named("Canada")), "This number rings Canada.")
    }
}

/// The App-target half of the emergency hand-off: the sentence itself.
///
/// ⛔ `DialEntry` DECIDES, THIS SAYS IT, AND ONLY THE SAYING IS TESTABLE HERE.
/// The detection is pinned on the cheap Linux runner by `EmergencyNumberTests`;
/// what only the App target can reach is whether the copy names the Phone app,
/// which is the half that makes it a hand-off rather than a refusal.
@MainActor
final class EmergencyCopyTests: XCTestCase {
    func testTheEmergencyLineNamesThePhoneApp() {
        let line = DialerModel.entryProblem(.emergencyNumber)
        XCTAssertNotNil(line)
        XCTAssertTrue(line?.contains("Phone app") == true, "a bare refusal strands the caller")
    }

    /// ⛔ IT MUST NOT READ AS A CORRECTABLE MISTAKE. Telling somebody dialling an
    /// emergency number to add a country code is the failure this pins.
    func testTheEmergencyLineNeverAsksForACountryCode() {
        let line = DialerModel.entryProblem(.emergencyNumber) ?? ""
        XCTAssertFalse(line.lowercased().contains("country code"))
        XCTAssertFalse(line.lowercased().contains("too short"))
    }

    func testItIsDistinctFromEveryOtherRefusal() {
        let emergency = DialerModel.entryProblem(.emergencyNumber)
        for other: DialRefusal in [.missingCountryCode, .tooShort, .tooLong, .strayPlus] {
            XCTAssertNotEqual(DialerModel.entryProblem(other), emergency)
        }
    }
}
