import DistrictData
import DistrictModel
import Foundation
import XCTest

/// Whether a failed support write may be sent again.
///
/// ⛔ THE RULE IS THE CONSERVATIVE ONE AND THESE TESTS ARE WHERE IT IS PINNED: a
/// repeat is offered only when the failure PROVES the write did not happen. On this
/// surface the cost of getting it wrong is a second public comment in a customer's
/// own thread — a duplicate reply, or a second "Closed at the requester's request
/// by …" note on a request that was already closed.
final class SupportResubmitTests: XCTestCase {
    /// ⛔ A 4xx IS THE SERVER HAVING REFUSED BEFORE IT DID ANY WORK — the role
    /// guard, the Zod parse, a missing row, the rate limiter — so nothing was
    /// posted and a repeat is honest.
    func testAFourHundredRangeRefusalMayBeSentAgain() {
        for status in [400, 403, 404, 409, 429, 499] {
            XCTAssertEqual(
                SupportResubmit.after(.http(status: status, message: nil), .once).isAllowed,
                true,
                "HTTP \(status) proves the write did not land"
            )
        }
    }

    /// ⛔ A 5xx IS THE SERVER HAVING THROWN, WHICH IT CAN DO WHILE POSTING THE
    /// COMMENT, AFTER POSTING IT, OR WHILE SERIALISING THE ANSWER TO ONE THAT
    /// LANDED. Ambiguous, so the control does not come back.
    func testAServerErrorIsAmbiguousAndRefusesTheRepeat() {
        for status in [500, 502, 503, 504] {
            XCTAssertEqual(
                SupportResubmit.after(.http(status: status, message: nil), .once).isAllowed,
                false,
                "HTTP \(status) may have posted"
            )
        }
    }

    /// ⛔ NO ANSWER AT ALL IS THE LOST-RESPONSE CASE, which is precisely the one a
    /// one-tap repeat turns into a duplicate.
    func testATransportFailureRefusesTheRepeat() {
        XCTAssertEqual(SupportResubmit.after(.transport("offline"), .once), .refused)
    }

    /// ⛔ A DECODE FAILURE IS THE ONE THAT READS AS HARMLESS AND IS NOT. It is only
    /// ever produced from a **2xx** — `ApiErrorNormalizer` guards on `isSuccess`
    /// and every site in `SupportRepository` is an envelope check downstream of one
    /// — so the server answered success and the comment IS in the thread. A repeat
    /// posts a second one, guaranteed rather than possibly.
    func testADecodeFailureRefusesTheRepeatBecauseTheWriteLanded() {
        XCTAssertEqual(SupportResubmit.after(.decoding("drift"), .once), .refused)
    }

    /// ⚠️ A 3xx CANNOT REACH THE 400...499 WINDOW AND IS TREATED AS AMBIGUOUS, which
    /// is the safe direction for a status nobody on this surface has reasoned about.
    /// `ApiErrorNormalizer` maps anything outside 2xx to `.http`, so an unfollowed
    /// redirect arrives here as `.http(302, …)`.
    func testARedirectIsTreatedAsAmbiguousRatherThanAsARefusal() {
        XCTAssertEqual(SupportResubmit.after(.http(status: 302, message: nil), .once), .refused)
    }

    /// ⛔ AN IDEMPOTENT WRITE IS ALWAYS REPEATABLE, WHATEVER FAILED. Raising a
    /// request carries an idempotency key the server claims before it calls
    /// Atlassian, so a retry that sends the SAME key collapses onto the first
    /// request rather than making a second ticket.
    func testAnIdempotentWriteMayAlwaysBeSentAgain() {
        let failures: [ApiError] = [
            .http(status: 500, message: nil),
            .transport("offline"),
            .decoding("drift"),
            .http(status: 429, message: nil),
        ]
        for failure in failures {
            XCTAssertEqual(SupportResubmit.after(failure, .idempotent), .allowed)
        }
    }
}
