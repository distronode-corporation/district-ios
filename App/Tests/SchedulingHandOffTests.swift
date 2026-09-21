@testable import DistrictAI
import DistrictModel
import DistrictNetwork
import XCTest

/// The scheduling console's retirement, pinned end to end from the wire.
///
/// ⛔ THE BODY BELOW IS THE SERVER'S, COPIED VERBATIM FROM `0316fc2c`, KEY ORDER
/// INCLUDED. A test that constructed an `ApiError` by hand would prove the mapping
/// and not the contract; this one starts at the bytes, so a server that renames
/// `error` or drops `code` fails here rather than in front of a user.
final class SchedulingHandOffTests: XCTestCase {
    private static let retiredBody = Data("""
    {"error":"Scheduling for this workspace is managed on the web dashboard.","code":"scheduler_console_retired"}
    """.utf8)

    private static let sentence = "Scheduling for this workspace is managed on the web dashboard."

    func test_IOS_SCH_01_theRetiredConsoleBodyNormalisesToItsOwnSentence() {
        let error = ApiErrorNormalizer.apiError(statusCode: 410, body: Self.retiredBody)
        guard case let .http(status, message) = error else {
            return XCTFail("a 410 must normalise to .http, got \(error)")
        }
        XCTAssertEqual(status, 410)
        XCTAssertEqual(message, Self.sentence)
    }

    /// ⛔ THE SERVER'S SENTENCE REACHES THE SCREEN UNCHANGED. It is the only party
    /// that knows where the capability went; a client fallback would go stale the
    /// moment that answer changed.
    func test_IOS_SCH_02_theUserSeesTheServerSentence() {
        let text = FailureText.from(ApiErrorNormalizer.apiError(statusCode: 410, body: Self.retiredBody))
        XCTAssertEqual(text.message, Self.sentence)
    }

    /// ⛔ NEVER RETRYABLE. A 410 means gone; offering "try again" would re-fetch the
    /// identical refusal for as long as the user kept pressing.
    func test_IOS_SCH_03_a410OffersNoRetry() {
        let text = FailureText.from(ApiErrorNormalizer.apiError(statusCode: 410, body: Self.retiredBody))
        XCTAssertEqual(text.action, .none)
    }

    /// ⚠️ A 410 WITH NO BODY STILL SAYS SOMETHING TRUE. The fallback carries no guess
    /// about where the thing went, because the client does not know.
    func test_IOS_SCH_04_a410WithNoBodyFallsBackWithoutGuessing() {
        let text = FailureText.from(ApiErrorNormalizer.apiError(statusCode: 410, body: nil))
        XCTAssertEqual(text.message, "That is no longer available.")
        XCTAssertEqual(text.action, .none)
    }

    /// ⛔ THE 402 SENTENCE NAMES NO WEB DASHBOARD. Guideline 3.1.1 covers steering
    /// toward an external purchase as well as the purchase itself.
    func test_IOS_SCH_05_theInactiveSubscriptionLineDoesNotSteerToTheWeb() {
        let text = FailureText.from(ApiErrorNormalizer.apiError(statusCode: 402, body: nil))
        XCTAssertEqual(text.message, "This workspace's subscription is not active.")
        XCTAssertFalse(text.message.contains("distronode.com"))
        XCTAssertEqual(text.action, .none)
    }

    // MARK: - The statuses the hand-off client can return

    /// ⛔ THIS IS THE REACHABLE HALF OF `SchedulingModel.handOffNotice(for:)`, WHICH IS
    /// `private static` AND SO CANNOT BE CALLED FROM A TEST EVEN WITH `@testable`
    /// (that exposes `internal`, not `private`). The method is a 409 branch plus
    /// `FailureText.from(error).message` for everything else, so pinning `FailureText`
    /// on the statuses `SchedulingHandoffClient` actually returns covers the same
    /// mapping without pretending to reach further than it does.
    ///
    /// ⚠️ 401 AND 403 ARE DIFFERENT REMEDIES AND THE ROUTE ANSWERS BOTH: 401 with no
    /// bearer, 403 with one that does not verify. Only the first offers a sign-in.
    func test_IOS_SCH_15_handOffFailuresMapToASentenceAndTheRightAction() {
        let signIn = FailureText.from(ApiErrorNormalizer.apiError(statusCode: 401, body: nil))
        XCTAssertEqual(signIn.action, .signIn)

        for status in [403, 429, 400] {
            let text = FailureText.from(ApiErrorNormalizer.apiError(statusCode: status, body: nil))
            XCTAssertFalse(text.message.isEmpty, "HTTP \(status) must say something")
            XCTAssertNotEqual(
                text.action, .signIn,
                "HTTP \(status) is not a session problem and must not offer a sign-in"
            )
        }
    }

    /// ⚠️ A 403 IS NOT RETRYABLE: the role will not change because the button was
    /// pressed again.
    func test_IOS_SCH_16_aForbiddenHandOffOffersNoRetry() {
        XCTAssertEqual(
            FailureText.from(ApiErrorNormalizer.apiError(statusCode: 403, body: nil)).action,
            FailureText.Action.none
        )
    }
}
