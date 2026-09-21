import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The two writes against a number the workspace already holds, and the rule that decides
/// whether a failed one may be sent again.
///
/// ⛔ ONE OF THE TWO IS IRREVERSIBLE AND THE OTHER LOOKS HARMLESS AND IS NOT. Releasing a
/// number gives it back to the carrier's general pool, so it is generally unreclaimable
/// and the tenant's callers reach nothing; reconfiguring one restates an EU trunk binding
/// that, if dropped, leaves an EU DID ringing and answered on the wrong continent with a
/// 200 either way.
final class NumberWriteRepositoryTests: XCTestCase {
    // MARK: - Configure

    /// ⚠️ THE WORKSPACE IS IN THE **BODY** ON THESE TWO, which is the opposite of the
    /// registration routes in the same family: they read `req.json()` first and hand the
    /// parsed value to the role guard, so a query parameter alone is a 400.
    func testConfiguringANumberSendsBothValuesInTheBodyAndNoQueryAtAll() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await NumbersRepository(client: .repositoryTest(transport)).configureNumber(
            workspaceId: "ws_1",
            phoneNumber: "+14165550100"
        )

        XCTAssertEqual(result.successOnly?.success, true)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/numbers/configure"
        )
        XCTAssertEqual(transport.bodies.first, #"{"phoneNumber":"+14165550100","workspaceId":"ws_1"}"#)
    }

    /// ⛔ A **503 IS THE EU-TRUNK FAIL-CLOSED AND IS A REAL SENTENCE TO SHOW.** The route
    /// refuses rather than write number-level webhooks over a trunk-bound EU DID, because
    /// the degrade there is a state CHANGE dressed as a no-op: the number keeps ringing and
    /// is answered on the wrong continent, with a 200 and nothing visible in the response.
    func testTheEuTrunkRefusalArrivesAsA503CarryingItsOwnExplanation() async throws {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.configureNoEuTrunk, status: 503)

        let result = await NumbersRepository(client: .repositoryTest(transport)).configureNumber(
            workspaceId: "ws_1",
            phoneNumber: "+3720000100"
        )

        XCTAssertEqual(result.failureOnly?.httpStatus, 503)
        let message = try XCTUnwrap(result.failureOnly?.message)
        XCTAssertTrue(message.contains("EU bridge"), "the server's own explanation reaches the screen")
    }

    /// ⚠️ **403** IS THE CROSS-TENANT OWNERSHIP GUARD AND **409** IS A PROVIDER MISMATCH.
    /// Neither is a role refusal and neither is retryable, which is why both are passed
    /// through with the server's own wording rather than mapped onto one message.
    func testTheOwnershipAndProviderRefusalsStayDistinctOnConfigure() async {
        let foreign = RepositoryTransport(json: NumberProvisioningBodies.numberNotInWorkspace, status: 403)
        let mismatch = RepositoryTransport(json: NumberProvisioningBodies.providerMismatch, status: 409)

        let notOurs = await NumbersRepository(client: .repositoryTest(foreign)).configureNumber(
            workspaceId: "ws_1",
            phoneNumber: "+14165550100"
        )
        let wrongVendor = await NumbersRepository(client: .repositoryTest(mismatch)).configureNumber(
            workspaceId: "ws_1",
            phoneNumber: "+14165550100"
        )

        XCTAssertEqual(notOurs.failureOnly?.httpStatus, 403)
        XCTAssertEqual(notOurs.failureOnly?.message, NumberProvisioningBodies.numberNotInWorkspaceMessage)
        XCTAssertEqual(wrongVendor.failureOnly?.httpStatus, 409)
    }

    func testAConfigureBodyThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false}"#)

        let result = await NumbersRepository(client: .repositoryTest(transport)).configureNumber(
            workspaceId: "ws_1",
            phoneNumber: "+14165550100"
        )

        XCTAssertEqual(result.failureOnly, .decoding("SuccessResponse did not affirm success=true"))
    }

    // MARK: - Release

    /// ⚠️ A CLEAN RELEASE OMITS `warnings` ENTIRELY — absent, not an empty array — which is
    /// why the field is Optional and why `warningLines` exists.
    func testACleanReleaseCarriesNoWarningsAtAll() async throws {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await NumbersRepository(client: .repositoryTest(transport)).releaseNumber(
            workspaceId: "ws_1",
            phoneNumber: "+14165550100"
        )

        let response = try XCTUnwrap(result.successOnly)
        XCTAssertNil(response.warnings, "absent on a clean release")
        XCTAssertEqual(response.warningLines, [])
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/numbers/release"
        )
        XCTAssertEqual(transport.bodies.first, #"{"phoneNumber":"+14165550100","workspaceId":"ws_1"}"#)
    }

    /// ⛔ A **200 WITH `warnings` IS NOT A PARTIAL RELEASE, AND SWALLOWING THE ARRAY IS THE
    /// EXPENSIVE MISTAKE.** The number is gone; what failed is a cleanup step after the
    /// irreversible part — and one of those steps is ending the monthly charge, so a client
    /// that dropped this would leave an operator believing they had stopped a charge they
    /// had not. The flag is therefore carried through INSIDE the success, exactly as
    /// ``OwnedNumbersResponse/partial`` is.
    func testAReleaseWhoseChargeCouldNotBeEndedIsASuccessThatStillSaysSo() async throws {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.releaseWithWarnings)

        let result = await NumbersRepository(client: .repositoryTest(transport)).releaseNumber(
            workspaceId: "ws_1",
            phoneNumber: "+14165550100"
        )

        XCTAssertNil(result.failureOnly, "⛔ the number IS released; this is not an error")
        let response = try XCTUnwrap(result.successOnly)
        XCTAssertEqual(response.warningLines, [NumberProvisioningBodies.releaseChargeWarning])
    }

    /// ⛔ A **502 MEANS NOTHING WAS CHANGED**: the route refuses to run any cleanup after a
    /// carrier refusal, because every step below it assumes the number is gone. The
    /// surviving ownership row is what makes a retry possible at all.
    func testACarrierRefusalIsA502ThatChangedNothing() async {
        let transport = RepositoryTransport(json: NumberProvisioningBodies.releaseCarrierRefused, status: 502)

        let result = await NumbersRepository(client: .repositoryTest(transport)).releaseNumber(
            workspaceId: "ws_1",
            phoneNumber: "+14165550100"
        )

        XCTAssertEqual(result.failureOnly?.httpStatus, 502)
        XCTAssertNil(result.successOnly)
    }

    func testAReleaseBodyThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false}"#)

        let result = await NumbersRepository(client: .repositoryTest(transport)).releaseNumber(
            workspaceId: "ws_1",
            phoneNumber: "+14165550100"
        )

        XCTAssertEqual(result.failureOnly, .decoding("NumberReleaseResponse did not affirm success=true"))
    }

    // MARK: - Whether a failed write may be sent again

    /// ⛔ AN IDEMPOTENT CALL IS ALWAYS REPEATABLE, WHATEVER WENT WRONG. Configure, the
    /// document upload and the document removal all converge on the same state, so no
    /// failure mode makes a second attempt cost anything.
    func testAnIdempotentWriteMayAlwaysBeRepeated() {
        let cases: [ApiError] = [
            .http(status: 403, message: "Phone number not found in this workspace"),
            .http(status: 500, message: "Internal error"),
            .transport("offline"),
            .decoding("SuccessResponse did not affirm success=true"),
        ]
        for error in cases {
            XCTAssertTrue(
                NumberWriteResubmit.after(error, .idempotent).isAllowed,
                "an idempotent write is repeatable after \(error)"
            )
        }
    }

    /// ⛔ A NON-IDEMPOTENT WRITE IS REPEATABLE ONLY WHEN THE FAILURE **PROVES** IT DID NOT
    /// HAPPEN, which on this surface means a 4xx: the server refused before it did any
    /// work — the role guard, the ownership check against the hub index, the rate limiter,
    /// a malformed body — so nothing was spent.
    func testANonIdempotentWriteIsRepeatableOnlyAfterARefusal() {
        for status in [400, 403, 404, 409, 413, 415, 422, 429, 499] {
            XCTAssertTrue(
                NumberWriteResubmit.after(.http(status: status, message: nil), .once).isAllowed,
                "HTTP \(status) proves the write did not land"
            )
        }
    }

    /// ⛔ THE THREE AMBIGUOUS FAILURES DISARM THE CONTROL, AND `.decoding` IS THE ONE THAT
    /// READS AS HARMLESS. It is only ever produced from a **2xx** — `ApiErrorNormalizer`
    /// guards on `isSuccess` — so the server answered success and the write DID happen. A
    /// repeat spends it again, guaranteed rather than possibly. A 5xx and a transport
    /// failure are genuinely unknown, which is the same answer for a different reason.
    ///
    /// ⚠️ A 3xx CANNOT REACH THE 4xx BRANCH AND THAT IS DELIBERATE: `ApiErrorNormalizer`
    /// maps anything outside 2xx to `.http`, so an unfollowed redirect arrives as
    /// `.http(302, …)` and is treated as ambiguous — the safe direction for a status nobody
    /// on this surface has reasoned about.
    func testAnAmbiguousFailureRefusesToRearmANonIdempotentWrite() {
        let ambiguous: [ApiError] = [
            .http(status: 500, message: "Internal error"),
            .http(status: 502, message: "The carrier did not release this number"),
            .http(status: 302, message: nil),
            .transport("The network connection was lost."),
            .decoding("NumberReleaseResponse did not affirm success=true"),
        ]
        for error in ambiguous {
            let outcome = NumberWriteResubmit.after(error, .once)
            XCTAssertFalse(outcome.isAllowed, "\(error) does not prove the write was skipped")
            XCTAssertEqual(outcome, .refused)
        }
    }

    /// ⚠️ THE 4xx BRANCH IS SAFE HERE FOR A REASON WORTH PINNING, BECAUSE IT IS NOT SAFE
    /// EVERYWHERE. On the release route a **403** AFTER a successful release is the
    /// EXPECTED answer — the ownership row the guard needs has just been deleted — so a
    /// re-armed control that is pressed again gets the same 403 and spends nothing. What
    /// makes that acceptable is that the second failure is also free; it is emphatically
    /// not evidence the first attempt failed, and a screen must not word it that way.
    func testAPostReleaseOwnershipRefusalReArmsAndStillSpendsNothing() {
        let afterRelease = ApiError.http(status: 403, message: NumberProvisioningBodies.numberNotInWorkspaceMessage)

        XCTAssertEqual(NumberWriteResubmit.after(afterRelease, .once), .allowed)
        XCTAssertTrue(NumberWriteResubmit.after(afterRelease, .once).isAllowed)
    }
}
