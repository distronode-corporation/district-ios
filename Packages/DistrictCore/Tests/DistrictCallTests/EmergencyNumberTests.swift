@testable import DistrictCall
import XCTest

/// ⛔ THE ORDERING IS THE SUBJECT OF THIS FILE, NOT THE REFUSAL. Without the
/// emergency check running first, `911` is still refused — as
/// ``DialRefusal/missingCountryCode``, whose copy reads "Start with a country code,
/// for example +1". Following that produces `+1911`, refused again as
/// ``DialRefusal/tooShort``. So a test asserting only "911 cannot be dialled"
/// passes against the broken behaviour. Every case below
/// asserts the SPECIFIC refusal, which is the only thing that distinguishes the
/// hand-off from the dead end.
final class EmergencyNumberTests: XCTestCase {
    func testEmergencyCodesAreHandedOffRatherThanSentHuntingForACountryCode() {
        for code in DialEntry.emergencyNumbers {
            let assessment = DialEntry.assess(code)
            XCTAssertEqual(
                assessment.refusal, .emergencyNumber,
                "\(code) must reach the hand-off, not a country-code correction"
            )
            XCTAssertNotEqual(assessment.refusal, .missingCountryCode, "\(code) regressed to the old path")
            XCTAssertFalse(assessment.isDialable, "\(code) must never be dialable")
        }
    }

    /// ⛔ THE SHAPE THE OLD COPY CREATED. A user who did exactly what the app told
    /// them must land on the hand-off, not on "too short".
    func testTheCountryCodedShapeTheOldCopySteeredIntoIsAlsoHandedOff() {
        for code in ["+1911", "+1112", "+1999"] {
            let assessment = DialEntry.assess(code)
            XCTAssertEqual(assessment.refusal, .emergencyNumber, "\(code) is what the old advice produced")
            XCTAssertNotEqual(assessment.refusal, .tooShort, "\(code) regressed to the old path")
        }
    }

    /// ⚠️ WHOLE MATCH, NEVER A PREFIX: an ordinary NANP number starting 911 must
    /// still dial, and a partial entry must not flash an emergency message.
    func testOrdinaryNumbersBeginningWithAnEmergencyCodeStillDial() {
        let assessment = DialEntry.assess("+19115550100")
        XCTAssertNil(assessment.refusal)
        XCTAssertTrue(assessment.isDialable)
    }

    func testAnEmergencyCodeEmbeddedInALongerEntryIsNotAHandOff() {
        XCTAssertNotEqual(DialEntry.assess("+441119999999").refusal, .emergencyNumber)
    }

    /// ⚠️ 112 AND 911 ARE THE TWO 3GPP TS 22.101 §10.1 REQUIRES OF EVERY HANDSET.
    /// Pinned by name so a future trim of the set cannot quietly drop them.
    func testTheTwoMandatoryGsmCodesArePresent() {
        XCTAssertTrue(DialEntry.emergencyNumbers.contains("112"))
        XCTAssertTrue(DialEntry.emergencyNumbers.contains("911"))
    }

    func testAnEmptyEntryIsStillEmptyRatherThanAnEmergency() {
        XCTAssertEqual(DialEntry.assess("   ").refusal, .empty)
    }
}
