import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The scheduling card's two calls.
///
/// ⛔ THE ASSERTIONS HERE ARE ABOUT WHICH OUTCOMES STAY DISTINCT, because three
/// separate things on this surface all look like "it did not work" and mean
/// different things to the person reading the card: no tenancy at all (offer the
/// button), a 202 that says the provision failed (show the sentence), and a 403 or
/// 429 that says the call never reached the provisioner (show a refusal). Folding
/// any pair together produces a screen that is confidently wrong.
///
/// ⚠️ NEITHER ROUTE CARRIES A `success` ENVELOPE, so the bodies below deliberately
/// have no such key. That is asserted rather than assumed — a repository that
/// reached for `ResponseEnvelope.affirm` would fail every one of these.
final class SchedulingRepositoryTests: XCTestCase {
    // MARK: - Status

    func testReadingTheStatusGetsTheSchedulingRouteWithTheWorkspaceInTheQuery() async {
        let transport = RepositoryTransport(json: SchedulingBodies.status(tenant: SchedulingBodies.readyTenant))

        let result = await SchedulingRepository(client: .repositoryTest(transport)).status(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.tenant?.status, .ready)
        XCTAssertEqual(transport.requests.first?.method, .get)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/scheduling/status?workspaceId=ws_1"
        )
        // ⛔ A GET WITH NO BODY. The workspace travels in the query here and in the
        // body on enable, which is the two routes' own asymmetry rather than a
        // choice available to this client.
        XCTAssertTrue(transport.bodies.isEmpty)
    }

    /// ⛔ THE BODY CARRIES NO `success` KEY AND THAT IS THE CONTRACT, NOT A THIN
    /// FIXTURE. Almost every district route answers `{success, …}` and this layer
    /// checks that flag by hand; these two do not send one, so a repository that
    /// affirmed an envelope would turn every healthy response into a decode
    /// failure. Pinned explicitly because the mistake is a one-line copy from any
    /// neighbouring repository.
    func testAStatusBodyWithNoSuccessEnvelopeIsStillASuccess() async {
        let transport = RepositoryTransport(json: #"{"eligible":true,"canManage":true,"tenant":null}"#)

        let result = await SchedulingRepository(client: .repositoryTest(transport)).status(workspaceId: "ws_1")

        XCTAssertNil(result.failureOnly, "there is no envelope flag to fail on")
        XCTAssertEqual(result.successOnly?.eligible, true)
    }

    /// ⛔ NO TENANCY IS A STATE, NEVER AN ERROR. This is every workspace before
    /// anyone presses Enable; reporting it as a failure would tell a customer
    /// something is broken when the answer is simply "not set up yet". ⚠️ And it
    /// is not the same fact as `eligible`, which is why both are carried: admitted
    /// with no row means offer the button, and a row with `eligible: false` means
    /// a workspace that was provisioned and later removed from the allowlist.
    func testTheLegacyNoTenancyStateIsASuccessCarryingNil() async throws {
        let transport = RepositoryTransport(json: SchedulingBodies.status(tenant: nil))

        let result = await SchedulingRepository(client: .repositoryTest(transport)).status(workspaceId: "ws_1")

        XCTAssertNil(result.failureOnly)
        let response = try XCTUnwrap(result.successOnly)
        XCTAssertTrue(response.eligible)
        XCTAssertNil(response.tenant, "no row, and the screen offers Enable rather than an error")
    }

    /// ⚠️ A `viewer` READS THE CARD AND GETS NO BUTTON. `canManage` is the server
    /// telling the client which controls to draw rather than leaving it to
    /// re-derive that from a role string — and, like every role signal on this
    /// surface, it is a UX affordance and not the boundary: the enable route
    /// enforces the role itself and answers 403 regardless of what was drawn.
    func testAViewerReadsTheSameFactsWithCanManageFalse() async {
        let transport = RepositoryTransport(
            json: SchedulingBodies.status(tenant: SchedulingBodies.readyTenant, canManage: false)
        )

        let result = await SchedulingRepository(client: .repositoryTest(transport)).status(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.canManage, false)
        XCTAssertEqual(result.successOnly?.tenant?.bookingUrl, "https://acme-book.distronode.com/book/x")
    }

    /// ⛔ A 500 IS NOT AN ABSENT TENANCY. The route's catch branch answers
    /// `{error}` on a 500, and a client that mapped it onto "no tenancy" would
    /// offer Enable to a workspace that already has booking pages — pressing it is
    /// harmless (the provisioner reuses the row) but the card would be stating
    /// something it does not know.
    func testAServerFailureIsAnErrorRatherThanAnAbsentTenancy() async {
        let transport = RepositoryTransport(json: #"{"error":"Could not read the tenancy"}"#, status: 500)

        let result = await SchedulingRepository(client: .repositoryTest(transport)).status(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly?.httpStatus, 500)
        XCTAssertNil(result.successOnly)
    }

    // MARK: - Enable

    /// ⛔ THE ROUTE ANSWERS **202**, AND A CLIENT THAT ONLY ACCEPTED 200 WOULD
    /// REPORT EVERY SUCCESSFUL ENABLE AS A FAILURE — with the tenancy actually
    /// provisioned and the screen claiming otherwise, which is the worst pairing
    /// available here. `ApiErrorNormalizer.isSuccess` is `200...299`, so nothing
    /// special is needed; this test is what proves that rather than assuming it.
    func testAn202EnableIsASuccessAndPostsTheWorkspaceInTheBody() async {
        let transport = RepositoryTransport(json: SchedulingBodies.enableOk, status: 202)

        let result = await SchedulingRepository(client: .repositoryTest(transport)).enable(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.ok, true)
        XCTAssertEqual(result.successOnly?.tenantStatus, .ready)
        XCTAssertNil(result.failureOnly)
        XCTAssertEqual(transport.requests.first?.method, .post)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/scheduling/enable"
        )
        XCTAssertEqual(transport.bodies.first, #"{"workspaceId":"ws_1"}"#)
    }

    /// ⛔ `ok: false` INSIDE A 202 IS A SUCCESSFUL DECODE CARRYING A SENTENCE, NOT
    /// AN ``ApiError``. The provision ran and failed; `error` is the
    /// operator-facing reason and the same text the status route will report as
    /// `lastError`. Promoting this to a transport failure would throw away the one
    /// string that says what went wrong and replace it with "something went wrong".
    func testAFailedProvisionInsideA202IsASuccessCarryingTheReason() async {
        let transport = RepositoryTransport(json: SchedulingBodies.enableFailed, status: 202)

        let result = await SchedulingRepository(client: .repositoryTest(transport)).enable(workspaceId: "ws_1")

        XCTAssertNil(result.failureOnly, "the 202 is a successful response; the refusal is in the body")
        let response = result.successOnly
        XCTAssertEqual(response?.ok, false)
        XCTAssertEqual(response?.tenantStatus, .error)
        XCTAssertEqual(response?.error, "cloudflare refused the dns record (HTTP 403)")
    }

    /// ⛔ THE ALLOWLIST REFUSAL IS A REAL ``ApiError`` AND MUST STAY ONE. It never
    /// reached the provisioner: `isSchedulingEnabledFor` refused before any third
    /// party was touched, so there is no tenancy state to report and nothing in the
    /// body but the sentence. ⚠️ It is also NOT the role gate — an owner of a
    /// workspace nobody has admitted gets this too, which is why the card reads
    /// `eligible` from the status route instead of offering the button by role.
    func testTheAllowlistRefusalPassesThroughAsA403() async {
        let transport = RepositoryTransport(
            json: #"{"error":"Scheduling is not enabled for this workspace"}"#,
            status: 403
        )

        let result = await SchedulingRepository(client: .repositoryTest(transport)).enable(workspaceId: "ws_1")

        XCTAssertEqual(
            result.failureOnly,
            .http(status: 403, message: "Scheduling is not enabled for this workspace")
        )
        XCTAssertNil(result.successOnly)
    }

    /// ⛔ 429 IS THE 5-PER-HOUR-PER-WORKSPACE BRAKE, AND IT IS A REFUSAL RATHER
    /// THAN A REASON TO RETRY. Each enable reaches two third parties — a tenancy
    /// at the scheduler and a DNS record at Cloudflare — so a client that retried
    /// on this would be spending somebody else's quota. ⚠️ Keyed on the WORKSPACE,
    /// so three colleagues pressing the same button share one budget; the sentence
    /// says so and reaches the screen intact.
    func testTheRateLimitPassesThroughAsA429WithItsSentence() async {
        let transport = RepositoryTransport(json: SchedulingBodies.rateLimited, status: 429)

        let result = await SchedulingRepository(client: .repositoryTest(transport)).enable(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly?.httpStatus, 429)
        XCTAssertEqual(result.failureOnly?.message, SchedulingBodies.rateLimitSentence)
    }

    /// ⚠️ ONE CALL PER PRESS AND NOTHING ELSE. Stated as a test because the
    /// tempting shape for a 202 is "fire it, then poll the status until it
    /// settles", and this route is the one place on the surface where that would
    /// create real records at two third parties on a loop. A caller re-reads the
    /// status on a human action instead.
    func testEnablingDoesNotChaseTheProvisionWithASecondRequest() async {
        let transport = RepositoryTransport(json: SchedulingBodies.enableOk, status: 202)

        _ = await SchedulingRepository(client: .repositoryTest(transport)).enable(workspaceId: "ws_1")

        XCTAssertEqual(transport.requests.count, 1, "no poll, no retry, no follow-up read")
    }
}

/// Minimal, VALID bodies for the two scheduling shapes.
///
/// ⚠️ NOT THE CONTRACT FIXTURES. `district-scheduling-*.json` pins the wire shape
/// through the strict gate; what lives here is the smallest body that satisfies
/// the Swift type, so these tests can be about outcomes and paths rather than
/// about JSON. ⛔ None of them carries a `success` key, because neither route
/// sends one.
private enum SchedulingBodies {
    static let readyTenant = #"""
    {"status":"ready","publicHost":"acme-book.distronode.com","region":"us",
     "lastReadyAt":"2026-09-06T11:20:00.000Z","lastError":null,"hasCredentials":true,
     "bookingUrl":"https://acme-book.distronode.com/book/x"}
    """#

    static func status(tenant: String?, eligible: Bool = true, canManage: Bool = true) -> String {
        #"""
        {"eligible":\#(eligible),"canManage":\#(canManage),"tenant":\#(tenant ?? "null")}
        """#
    }

    static let enableOk = #"""
    {"ok":true,"status":"ready","publicHost":"acme-book.distronode.com","error":null}
    """#

    static let enableFailed = #"""
    {"ok":false,"status":"error","publicHost":"acme-book.distronode.com",
     "error":"cloudflare refused the dns record (HTTP 403)"}
    """#

    /// ⛔ BUILT BY CONCATENATION RATHER THAN WRAPPED INSIDE THE JSON. A raw
    /// multi-line string may break between JSON tokens, but a newline INSIDE a
    /// string value is invalid JSON, and the failure it produces reads as a bug in
    /// the repository under test rather than in the fixture.
    static let rateLimited = #"{"error":"\#(rateLimitSentence)"}"#

    static let rateLimitSentence = "Scheduling has been enabled several times in the last hour "
        + "for this workspace. Please try again shortly."
}
