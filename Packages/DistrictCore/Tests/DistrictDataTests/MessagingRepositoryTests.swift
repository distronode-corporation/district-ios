import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The messaging account READ, and the upsert that edits or creates one.
///
/// ⛔ THE REQUEST BYTES MATTER MORE ON THIS SURFACE THAN ANYWHERE ELSE IN THE
/// PACKAGE, and the reason is the route rather than the client. Five messaging calls
/// are the SAME url and the SAME verb, told apart only by an `action` string in the
/// body, and the route's switch falls through to the UPSERT on an unrecognised
/// action. So a missing or misspelled action does not fail: it edits a carrier
/// account. Every write asserts the encoded document, not just the outcome.
///
/// ⚠️ THE OTHER THREE MESSAGING SUITES ARE `MessagingDefaultRepositoryTests`,
/// `MessagingChannelMetaRepositoryTests` and `MessagingProbeRepositoryTests`. They
/// are split by SURFACE and not by kind, because SwiftLint's 500-line file ceiling
/// is an error under `--strict` and one suite for seven methods with their reasoning
/// attached does not fit.
final class MessagingRepositoryTests: XCTestCase {
    // MARK: - The account read

    func testReadingAccountsGetsTheMessagingRouteAndAnswersTheWholeEnvelope() async {
        let transport = RepositoryTransport(json: MessagingBodies.accounts)

        let result = await MessagingRepository.testing(transport).accounts(workspaceId: "ws_1")

        let response = result.successOnly
        XCTAssertEqual(response?.accounts.map(\.id), ["acct-a", "acct-b"])
        XCTAssertEqual(response?.defaultAccountId, "acct-b")
        XCTAssertEqual(response?.managedAccount?.phoneNumbers, ["+14165550190"])
        XCTAssertEqual(response?.channelDefaults, ["sms": "acct-a"])
        XCTAssertEqual(transport.requests.first?.method, .get)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/messaging?workspaceId=ws_1"
        )
        XCTAssertTrue(transport.bodies.isEmpty, "a GET carries no body")
    }

    /// ⛔ A FRESH WORKSPACE IS A SUCCESS AND MUST NOT READ AS A FAILURE, and its
    /// three absences are three different facts: no accounts of its own, no
    /// platform-purchased numbers, and therefore no default sender. A screen that
    /// collapsed them would tell a workspace it cannot send when the platform may
    /// hold numbers for it, or the reverse.
    func testAFreshWorkspaceIsASuccessWithNoAccountsAndNoDefault() async {
        let transport = RepositoryTransport(json: MessagingBodies.unmanaged)

        let result = await MessagingRepository.testing(transport).accounts(workspaceId: "ws_1")

        XCTAssertNil(result.failureOnly)
        XCTAssertEqual(result.successOnly?.accounts.isEmpty, true)
        XCTAssertNil(result.successOnly?.managedAccount)
        XCTAssertNil(result.successOnly?.defaultAccountId)
        XCTAssertEqual(result.successOnly?.channelDefaults.isEmpty, true)
    }

    /// ⛔ THE ENVELOPE CHECK IS NOT REDUNDANT WITH THE DTO'S REQUIRED FIELDS. A
    /// required field rejects `{}`; it does not reject a well-formed `success: false`,
    /// which this route's catch branch produces on a 200 once the headers are
    /// written. Without it, "we could not look" renders as "this workspace sends
    /// through nothing" on the screen an operator opens precisely because a message
    /// went out from the wrong identity.
    func testAnAccountReadThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(
            json: #"{"success":false,"accounts":[],"managedAccount":null,"channelDefaults":{}}"#
        )

        let result = await MessagingRepository.testing(transport).accounts(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly, .decoding("MessagingResponse did not affirm success=true"))
    }

    /// ⚠️ THIS READ ADMITS `viewer`, so a 403 on it means something else than it does
    /// on the writes: not a member at all, or a workspace id that is not theirs. ⛔
    /// The 401 and the 503 are the two it has to stay distinct from, one ending the
    /// session and the other worth retrying.
    func testARefusedAccountReadAndAnOutageKeepTheirStatuses() async {
        let forbidden = RepositoryTransport(json: MessagingBodies.forbidden, status: 403)
        let refused = await MessagingRepository.testing(forbidden).accounts(workspaceId: "ws_1")
        XCTAssertEqual(refused.failureOnly, .http(status: 403, message: "Forbidden"))
        XCTAssertEqual(refused.failureOnly?.isUnauthorized, false, "403 is not a token problem")

        let expired = RepositoryTransport(json: MessagingBodies.unauthorized, status: 401)
        let unauthorized = await MessagingRepository.testing(expired).accounts(workspaceId: "ws_1")
        XCTAssertEqual(unauthorized.failureOnly?.isUnauthorized, true)

        let degraded = RepositoryTransport(json: MessagingBodies.degraded, status: 503)
        let transient = await MessagingRepository.testing(degraded).accounts(workspaceId: "ws_1")
        XCTAssertEqual(transient.failureOnly?.httpStatus, 503)
        XCTAssertNil(transient.successOnly)
    }

    // MARK: - Saving an account

    /// ⛔ THE UPSERT CARRIES NO `action` KEY, AND THAT IS THE ASSERTION. It is the
    /// route's DEFAULT switch arm, so adding an action would change which branch
    /// runs. The absence reads as an omission and is the contract.
    ///
    /// ⚠️ AND NO SECRET IS IN THIS BODY. An ordinary edit sends `providerConfig` with
    /// whatever the form holds and omits every credential field, because a blank or
    /// absent secret means "keep the stored ciphertext". That is what makes an edit
    /// form possible at all against a read that returns no credentials.
    func testEditingAnAccountSendsNoActionAndNoSecret() async throws {
        let transport = RepositoryTransport(json: MessagingBodies.saved)
        let draft = MessagingAccountDraft(
            activeProvider: "twilio",
            credentialSource: "byok",
            providerConfig: .object(["phoneNumbers": .array([.string("+14165550111")])]),
            accountId: "acct-a",
            label: "Twilio (renamed)"
        )

        let result = await MessagingRepository.testing(transport).saveAccount(
            workspaceId: "ws_1",
            account: draft
        )

        XCTAssertEqual(result.successOnly?.accountId, "acct-a")
        XCTAssertEqual(result.successOnly?.defaultAccountId, "acct-b", "not the row just saved")
        XCTAssertEqual(transport.requests.first?.method, .patch)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/messaging"
        )
        let body = try XCTUnwrap(transport.bodies.first)
        XCTAssertEqual(
            body,
            #"{"accountId":"acct-a","activeProvider":"twilio","credentialSource":"byok","#
                + #""label":"Twilio (renamed)","#
                + #""providerConfig":{"phoneNumbers":["+14165550111"]},"workspaceId":"ws_1"}"#
        )
        XCTAssertFalse(body.contains("authToken"), "⛔ an edit types no credential")
        XCTAssertFalse(body.contains(#""action""#), "⛔ the upsert is the route's default branch")
    }

    /// ⛔ A NIL `accountId` IS A CREATE, AND A CREATE IS NOT IDEMPOTENT: the route
    /// mints `acct-<uuid>` inside the transaction, so two deliveries are two accounts
    /// with two copies of the credentials. Asserted as a request COUNT because "one
    /// call per press" is the only protection available.
    ///
    /// ⚠️ THE KEY IS DROPPED RATHER THAN SENT AS NULL, which is what distinguishes a
    /// create from an edit on the wire. ``JSONValue/object(_:)`` drops a nil pair
    /// silently by design, so this is a question about the encoded document.
    func testCreatingAnAccountOmitsTheIdAndSendsExactlyOneRequest() async {
        let transport = RepositoryTransport(json: MessagingBodies.saved)

        _ = await MessagingRepository.testing(transport).saveAccount(
            workspaceId: "ws_1",
            account: MessagingBodies.draft(makeDefault: true)
        )

        XCTAssertEqual(
            transport.requests.count,
            1,
            "⛔ never retried: a second delivery is a second account"
        )
        XCTAssertEqual(
            transport.bodies.first,
            #"{"activeProvider":"twilio","credentialSource":"byok","makeDefault":true,"#
                + #""providerConfig":{},"workspaceId":"ws_1"}"#
        )
    }

    func testAnAccountSaveThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false}"#)

        let result = await MessagingRepository.testing(transport).saveAccount(
            workspaceId: "ws_1",
            account: MessagingBodies.draft()
        )

        XCTAssertEqual(
            result.failureOnly,
            .decoding("MessagingAccountSaveResponse did not affirm success=true")
        )
    }

    /// ⛔ THE 502 IS NOT A REFUSAL AND ITS SENTENCE SURVIVES, WHICH IS THE WHOLE
    /// REASON THIS CLIENT NEEDS NO `Unverifiable` OUTCOME TYPE. The route separates
    /// that status from its three 403s on purpose: the carrier-ownership probe could
    /// not reach the carrier, so the number stays unclaimed and retrying shortly is
    /// correct. ``ApiError`` keeps both the status and the authored sentence naming
    /// the number, so a caller can say exactly that. ⛔ If an App-side failure-text
    /// layer is ever added with a blanket 5xx rule, it must special-case 502 here or
    /// this information is lost in precisely the way the Kotlin client invented a
    /// type to prevent.
    ///
    /// ⚠️ A 403 IS ASSERTED BESIDE IT so the pair is visibly different: "not entitled
    /// to managed credentials" is a refusal an operator can act on and must not be
    /// worded as an outage.
    func testTheCarrierProbeOutageIsA502WhoseSentenceSurvives() async {
        let unreachable = RepositoryTransport(json: MessagingBodies.unverifiable, status: 502)
        let outage = await MessagingRepository.testing(unreachable).saveAccount(
            workspaceId: "ws_1",
            account: MessagingBodies.draft()
        )
        XCTAssertEqual(outage.failureOnly?.httpStatus, 502)
        XCTAssertEqual(outage.failureOnly?.message, MessagingBodies.unverifiableSentence)

        let notEntitled = RepositoryTransport(json: MessagingBodies.notEntitled, status: 403)
        let refused = await MessagingRepository.testing(notEntitled).saveAccount(
            workspaceId: "ws_1",
            account: MessagingBodies.draft()
        )
        XCTAssertEqual(refused.failureOnly?.httpStatus, 403)
        XCTAssertEqual(refused.failureOnly?.message, MessagingBodies.notEntitledSentence)

        let expired = RepositoryTransport(json: MessagingBodies.unauthorized, status: 401)
        let unauthorized = await MessagingRepository.testing(expired).saveAccount(
            workspaceId: "ws_1",
            account: MessagingBodies.draft()
        )
        XCTAssertEqual(unauthorized.failureOnly?.isUnauthorized, true)

        let degraded = RepositoryTransport(json: MessagingBodies.degraded, status: 503)
        let transient = await MessagingRepository.testing(degraded).saveAccount(
            workspaceId: "ws_1",
            account: MessagingBodies.draft()
        )
        XCTAssertEqual(transient.failureOnly?.httpStatus, 503)
        XCTAssertNil(transient.successOnly)
    }
}
