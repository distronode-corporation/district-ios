import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The carrier credential probe.
///
/// ⛔ THE STUB TRANSPORT IS THE ONLY THING THIS METHOD IS EVER POINTED AT, AND THAT
/// IS NOT A STYLE RULE. Every live request makes one authenticated third-party call
/// with the credentials taken from the body: Twilio `accounts.fetch`, Sinch's numbers
/// list AND a dry-run batch list, or a Telnyx `/v2/balance` read. Those leave the
/// platform's own egress, under its reputation, against an account this client does
/// not own, and the route is a clean credential-validation oracle by design. A test
/// that drove it live would be sorting somebody's carrier keys at our expense, and
/// enough volume gets the egress throttled or blocked by the carrier for EVERY tenant
/// at once. The server's guard is 10/min per workspace and it is Redis-backed and
/// FAIL-OPEN, so it is not a backstop.
///
/// ⛔ AND THIS IS THE ONE REPOSITORY METHOD IN THE PACKAGE THAT DELIBERATELY DOES NOT
/// RUN THE ENVELOPE GUARD. A rejected credential is an HTTP **200** carrying
/// `success: false`, which is the button's entire purpose; affirming the envelope
/// would report "this version of the app does not understand the response" for it.
/// That is asserted below rather than commented, because it is one line of copy-paste
/// from any sibling method away from being wrong.
final class MessagingProbeRepositoryTests: XCTestCase {
    /// ⚠️ ONE REQUEST PER CALL, ASSERTED, because a redraw-driven or retried probe is
    /// the failure mode that matters here rather than a wrong body.
    func testAPassedProbePostsThePlaintextConfigOnceAndCarriesTheDetail() async {
        let transport = RepositoryTransport(json: MessagingBodies.probePassed)

        let result = await MessagingRepository.testing(transport).testCredentials(
            workspaceId: "ws_1",
            providerConfig: .object([
                "provider": .string("twilio"),
                "accountSid": .string("AC_typed"),
            ])
        )

        XCTAssertEqual(result.successOnly?.success, true)
        XCTAssertEqual(result.successOnly?.detail, "Distronode Contract")
        XCTAssertEqual(transport.requests.count, 1, "⛔ never on a loop, a redraw or a retry")
        XCTAssertEqual(transport.requests.first?.method, .post)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/messaging/test"
        )
        // ⛔ THE CREDENTIALS TRAVEL IN PLAINTEXT AND HAVE NOT BEEN SAVED, which is
        // what makes the call possible at all: the stored ones are KMS-wrapped and
        // this route has nothing to decrypt them with. It is also what bounds the
        // call to a form that actually holds them.
        XCTAssertEqual(
            transport.bodies.first,
            #"{"providerConfig":{"accountSid":"AC_typed","provider":"twilio"},"workspaceId":"ws_1"}"#
        )
    }

    /// ⛔ THE ASSERTION THIS SUITE EXISTS FOR. A rejected credential is an HTTP **200**
    /// carrying `success: false`, and it must arrive as a SUCCESS holding the carrier's
    /// sentence. Running the envelope guard here would report "this version of the app
    /// does not understand the response" for the button's only interesting outcome,
    /// with no retry offered, on a working app talking to a working server.
    ///
    /// ⚠️ THE SENTENCE QUOTES THE CARRIER, error code and all. "Authenticate (20003)"
    /// is searchable in Twilio's own documentation and nothing this client could invent
    /// would be, which is why it is forwarded verbatim.
    func testARejectedCredentialIsASuccessCarryingTheCarriersSentence() async {
        let transport = RepositoryTransport(json: MessagingBodies.probeRejected)

        let result = await MessagingRepository.testing(transport).testCredentials(
            workspaceId: "ws_1",
            providerConfig: .object(["provider": .string("twilio")])
        )

        XCTAssertNil(result.failureOnly, "⛔ NOT a decode failure: this is the answer")
        XCTAssertEqual(result.successOnly?.success, false)
        XCTAssertEqual(result.successOnly?.error, "Authenticate (20003)")
        XCTAssertNil(result.successOnly?.detail)
    }

    /// ⛔ "WE COULD NOT ASK" IS NOT "YOUR KEYS ARE WRONG", and the two must never be
    /// merged: on this screen believing the second leads to re-typing a live carrier
    /// secret. A 429 is the 10/min cap, a 401 is this app's own session, a 403 is the
    /// role gate, and a 503 is an outage. None of them is evidence about the
    /// credentials.
    func testEveryTransportAndStatusFailureSaysNothingAboutTheCredentials() async {
        let config = JSONValue.object(["provider": .string("twilio")])

        let capped = RepositoryTransport(json: MessagingBodies.probeRateLimited, status: 429)
        let limited = await MessagingRepository.testing(capped).testCredentials(
            workspaceId: "ws_1",
            providerConfig: config
        )
        XCTAssertEqual(limited.failureOnly?.httpStatus, 429)
        XCTAssertEqual(limited.failureOnly?.message, MessagingBodies.probeRateLimitSentence)
        XCTAssertNil(limited.successOnly, "⛔ says nothing about the keys")

        let viewer = RepositoryTransport(json: MessagingBodies.forbidden, status: 403)
        let refused = await MessagingRepository.testing(viewer).testCredentials(
            workspaceId: "ws_1",
            providerConfig: config
        )
        XCTAssertEqual(refused.failureOnly?.httpStatus, 403)
        XCTAssertEqual(refused.failureOnly?.isUnauthorized, false)

        let expired = RepositoryTransport(json: MessagingBodies.unauthorized, status: 401)
        let unauthorized = await MessagingRepository.testing(expired).testCredentials(
            workspaceId: "ws_1",
            providerConfig: config
        )
        XCTAssertEqual(unauthorized.failureOnly?.isUnauthorized, true)

        let degraded = RepositoryTransport(json: MessagingBodies.degraded, status: 503)
        let transient = await MessagingRepository.testing(degraded).testCredentials(
            workspaceId: "ws_1",
            providerConfig: config
        )
        XCTAssertEqual(transient.failureOnly?.httpStatus, 503)
    }

    /// ⚠️ A 200 WHOSE BODY IS UNREADABLE IS STILL A FAILURE, and it is the one outcome
    /// the missing envelope guard does not cover: `success` is required on the DTO, so
    /// `{}` cannot decode. That is the line between "no envelope guard" and "no
    /// checking at all".
    func testAStructurallyEmptyProbeBodyIsADecodeFailure() async {
        let transport = RepositoryTransport(json: "{}")

        let result = await MessagingRepository.testing(transport).testCredentials(
            workspaceId: "ws_1",
            providerConfig: .object(["provider": .string("twilio")])
        )

        XCTAssertEqual(result.failureOnly?.isShapeMismatch, true)
        XCTAssertNil(result.successOnly)
    }
}
