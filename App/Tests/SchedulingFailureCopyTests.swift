@testable import DistrictAI
import DistrictData
import DistrictModel
import Foundation
import XCTest

/// The one mapping from a scheduling admin refusal to a sentence and an offer, one
/// case per error.
///
/// ⛔ THE FIVE CODE SENTENCES ARE THE WEB'S `SCHEDULING_ERROR_SENTENCES` VERBATIM, so
/// they are spelled out here rather than read back from the constants: an edit to a
/// constant has to fail a test, because it has to be an edit to the web's copy too.
final class SchedulingFailureCopyTests: XCTestCase {
    private func expect(
        _ error: SchedulingAdminError,
        says message: String,
        offers action: FailureText.Action,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let text = SchedulingFailureCopy.text(for: error)
        XCTAssertEqual(text.message, message, file: file, line: line)
        XCTAssertEqual(text.action, action, file: file, line: line)
    }

    // MARK: - A refusal at HTTP 200

    func testAScheduler200UnavailableOffersARetry() {
        expect(
            .failure(.unavailable),
            says: "The booking system did not answer. Try again in a minute.",
            offers: .retry
        )
    }

    /// ⚠️ THE ONE ARM WHOSE RECOVERY IS "CHOOSE SOMETHING ELSE": the identical request
    /// stays refused for as long as somebody else holds the slot.
    func testASlotTakenOffersNoRetry() {
        expect(.failure(.slotTaken), says: "That time was just taken. Pick another.", offers: .none)
    }

    func testAScheduler200ForbiddenOffersNoRetry() {
        expect(.failure(.forbidden), says: "You can view this but not change it.", offers: .none)
    }

    func testAScheduler200NotReadyOffersNoRetry() {
        expect(.failure(.notReady), says: "Scheduling is not set up for this workspace yet.", offers: .none)
    }

    /// ⛔ THE WEB'S SENTENCE SAYS "Try again", SO THE OFFER DOES TOO.
    func testAScheduler200UnknownOffersTheRetryItsSentenceNames() {
        expect(.failure(.unknown), says: "That did not save. Try again.", offers: .retry)
    }

    // MARK: - A refusal by status

    /// ⛔ A **400** KEEPS THE WEB'S SENTENCE AND OFFERS NO RETRY: the identical body is
    /// the identical refusal. The field names never reach the sentence either: they are
    /// zod paths, identifiers to look up and not prose.
    func testInvalidParamsSaysTheWebsSentenceOffersNoRetryAndNamesNoField() {
        let error = SchedulingAdminError.invalidParams(["msg_confirmation"])
        expect(error, says: "That did not save. Try again.", offers: .none)
        XCTAssertFalse(SchedulingFailureCopy.text(for: error).message.contains("msg_confirmation"))
    }

    func testAForbiddenStatusOffersNoRetry() {
        expect(.forbidden, says: "You can view this but not change it.", offers: .none)
    }

    func testANotReadyStatusOffersNoRetry() {
        expect(.notReady, says: "Scheduling is not set up for this workspace yet.", offers: .none)
    }

    func testAnUnavailableStatusOffersARetry() {
        expect(.unavailable, says: "The booking system did not answer. Try again in a minute.", offers: .retry)
    }

    func testAnUnclassifiedRefusalOffersTheRetryItsSentenceNames() {
        expect(.unknown, says: "That did not save. Try again.", offers: .retry)
    }

    // MARK: - The two the web cannot have

    /// ⚠️ THE SAME SENTENCE `FailureText.from(_:)` GIVES AN `ApiError.transport`, so
    /// one cause is worded once across the app.
    func testATransportFailureSaysOfflineAndOffersARetry() {
        expect(
            .transport("The Internet connection appears to be offline."),
            says: "You appear to be offline. Check your connection and try again.",
            offers: .retry
        )
        XCTAssertEqual(
            SchedulingFailureCopy.text(for: .transport("x")).message,
            FailureText.from(ApiError.transport("x")).message
        )
    }

    /// ⛔ CONTRACT DRIFT, NOT CONNECTIVITY, AND NEVER RETRYABLE: a second attempt cannot
    /// change a response shape this build cannot parse.
    func testADecodeFailureAsksForAnUpdateAndOffersNoRetry() {
        expect(
            .decoding("keyNotFound"),
            says: "This version of the app could not read that response. Please update.",
            offers: .none
        )
    }

    // MARK: - A thrown error

    func testAThrownAdminErrorTakesTheSameMapping() {
        let text = SchedulingFailureCopy.text(forAny: SchedulingAdminError.failure(.slotTaken))
        XCTAssertEqual(text.message, "That time was just taken. Pick another.")
        XCTAssertEqual(text.action, .none)
    }

    /// ⚠️ A THROW NOBODY CLASSIFIED IS THE `unknown` CODE, never a specific sentence it
    /// has not earned.
    func testAThrowFromElsewhereIsTheUnknownCode() {
        let text = SchedulingFailureCopy.text(forAny: CancellationError())
        XCTAssertEqual(text.message, "That did not save. Try again.")
        XCTAssertEqual(text.action, .retry)
    }

    func testOnlyASlotTakenRefusalIsSlotTaken() {
        XCTAssertTrue(SchedulingFailureCopy.isSlotTaken(SchedulingAdminError.failure(.slotTaken)))
        XCTAssertFalse(SchedulingFailureCopy.isSlotTaken(SchedulingAdminError.failure(.unavailable)))
        XCTAssertFalse(SchedulingFailureCopy.isSlotTaken(SchedulingAdminError.unknown))
        XCTAssertFalse(SchedulingFailureCopy.isSlotTaken(CancellationError()))
    }
}
