import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The two actions that answer `{success, defaultAccountId}`: pointing every send at
/// one account, and removing one.
///
/// ⛔ ONE RESPONSE TYPE FOR TWO ACTIONS WHOSE CONSEQUENCES ARE NOT REMOTELY EQUAL.
/// `setDefault` is idempotent and reversible; `delete` frees every phone number only
/// that account held, in the hub index that routes inbound calls and SMS, and another
/// tenant can then claim it. The shared shape is the server's, so the difference has
/// to live in the `action` string and in what a UI says before calling, which is why
/// both request bodies are pinned byte for byte here.
final class MessagingDefaultRepositoryTests: XCTestCase {
    // MARK: - The default sender

    /// ⚠️ THE ACTION IS `setDefault` AND IT IS IN THE BODY. There is no
    /// `messaging/default` path, so this string is the entire difference between
    /// re-pointing the workspace's sender and editing a carrier account.
    func testSettingTheDefaultCarriesItsActionAndEchoesTheNewDefault() async {
        let transport = RepositoryTransport(json: #"{"success":true,"defaultAccountId":"acct-a"}"#)

        let result = await MessagingRepository.testing(transport).setDefaultAccount(
            workspaceId: "ws_1",
            accountId: "acct-a"
        )

        XCTAssertEqual(result.successOnly?.defaultAccountId, "acct-a")
        XCTAssertEqual(transport.requests.first?.method, .patch)
        XCTAssertEqual(
            transport.bodies.first,
            #"{"accountId":"acct-a","action":"setDefault","workspaceId":"ws_1"}"#
        )
    }

    func testASetDefaultThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false,"defaultAccountId":"acct-a"}"#)

        let result = await MessagingRepository.testing(transport).setDefaultAccount(
            workspaceId: "ws_1",
            accountId: "acct-a"
        )

        XCTAssertEqual(
            result.failureOnly,
            .decoding("MessagingDefaultResponse did not affirm success=true")
        )
    }

    /// ⚠️ A 404 HERE MEANS THE LIST ON SCREEN IS STALE rather than that anything is
    /// broken: the id was not found in this workspace. ⛔ It is NOT folded into
    /// success the way a contact delete's 404 is, because pointing every send at an
    /// account that does not exist is not the outcome anyone asked for.
    func testAStaleAccountIdAndTheUsualFailuresPassThroughOnSetDefault() async {
        let missing = RepositoryTransport(json: Self.notFound, status: 404)
        let stale = await MessagingRepository.testing(missing).setDefaultAccount(
            workspaceId: "ws_1",
            accountId: "acct-gone"
        )
        XCTAssertEqual(stale.failureOnly, .http(status: 404, message: "Account not found"))
        XCTAssertNil(stale.successOnly, "⛔ not folded into success")

        let viewer = RepositoryTransport(json: MessagingBodies.forbidden, status: 403)
        let refused = await MessagingRepository.testing(viewer).setDefaultAccount(
            workspaceId: "ws_1",
            accountId: "acct-a"
        )
        XCTAssertEqual(refused.failureOnly?.httpStatus, 403)

        let expired = RepositoryTransport(json: MessagingBodies.unauthorized, status: 401)
        let unauthorized = await MessagingRepository.testing(expired).setDefaultAccount(
            workspaceId: "ws_1",
            accountId: "acct-a"
        )
        XCTAssertEqual(unauthorized.failureOnly?.isUnauthorized, true)

        let degraded = RepositoryTransport(json: MessagingBodies.degraded, status: 503)
        let transient = await MessagingRepository.testing(degraded).setDefaultAccount(
            workspaceId: "ws_1",
            accountId: "acct-a"
        )
        XCTAssertEqual(transient.failureOnly?.httpStatus, 503)
        XCTAssertNil(transient.successOnly)
    }

    // MARK: - Deleting an account

    /// ⛔ **PATCH WITH AN `action`, NOT A DELETE**, unlike contacts and knowledge: a
    /// DELETE to this path is a 405. ⛔ And it frees every phone number only this
    /// account held, which is why the request bytes are pinned rather than just the
    /// outcome.
    ///
    /// ⚠️ THE ECHOED DEFAULT MOVED WITHOUT BEING ASKED TO. `acct-b` was the default
    /// and was deleted, so the workspace now points at what is left, and this
    /// response is the only place that is announced.
    func testDeletingAnAccountUsesThePatchActionAndReportsTheMovedDefault() async {
        let transport = RepositoryTransport(json: #"{"success":true,"defaultAccountId":"acct-a"}"#)

        let result = await MessagingRepository.testing(transport).deleteAccount(
            workspaceId: "ws_1",
            accountId: "acct-b"
        )

        XCTAssertEqual(result.successOnly?.defaultAccountId, "acct-a", "the default MOVED, unasked")
        XCTAssertEqual(transport.requests.first?.method, .patch)
        XCTAssertEqual(
            transport.bodies.first,
            #"{"accountId":"acct-b","action":"delete","workspaceId":"ws_1"}"#
        )
    }

    /// ⚠️ DELETING THE LAST ACCOUNT DROPS THE KEY RATHER THAN NULLING IT, so "there
    /// is no default now" and "the field did not arrive" are the same value. That is
    /// a real limit of this response and the reason a delete is followed by a re-read
    /// rather than rendered from what it returns.
    func testDeletingTheLastAccountLeavesNoDefaultToReport() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await MessagingRepository.testing(transport).deleteAccount(
            workspaceId: "ws_1",
            accountId: "acct-a"
        )

        XCTAssertNil(result.failureOnly, "an absent default is not a failure")
        XCTAssertNil(result.successOnly?.defaultAccountId)
    }

    func testADeleteThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false,"defaultAccountId":"acct-a"}"#)

        let result = await MessagingRepository.testing(transport).deleteAccount(
            workspaceId: "ws_1",
            accountId: "acct-b"
        )

        XCTAssertEqual(
            result.failureOnly,
            .decoding("MessagingDefaultResponse did not affirm success=true")
        )
    }

    func testADeleteRefusalAndAnOutagePassThrough() async {
        let missing = RepositoryTransport(json: Self.notFound, status: 404)
        let stale = await MessagingRepository.testing(missing).deleteAccount(
            workspaceId: "ws_1",
            accountId: "acct-gone"
        )
        XCTAssertEqual(stale.failureOnly, .http(status: 404, message: "Account not found"))

        let viewer = RepositoryTransport(json: MessagingBodies.forbidden, status: 403)
        let refused = await MessagingRepository.testing(viewer).deleteAccount(
            workspaceId: "ws_1",
            accountId: "acct-b"
        )
        XCTAssertEqual(refused.failureOnly?.httpStatus, 403)

        let expired = RepositoryTransport(json: MessagingBodies.unauthorized, status: 401)
        let unauthorized = await MessagingRepository.testing(expired).deleteAccount(
            workspaceId: "ws_1",
            accountId: "acct-b"
        )
        XCTAssertEqual(unauthorized.failureOnly?.isUnauthorized, true)

        let degraded = RepositoryTransport(json: MessagingBodies.degraded, status: 503)
        let transient = await MessagingRepository.testing(degraded).deleteAccount(
            workspaceId: "ws_1",
            accountId: "acct-b"
        )
        XCTAssertEqual(transient.failureOnly?.httpStatus, 503)
        XCTAssertNil(transient.successOnly)
    }

    private static let notFound = #"{"success":false,"error":"Account not found"}"#
}

/// The per-channel sender override, and the creator cell number.
///
/// ⚠️ TWO SURFACES IN ONE SUITE BECAUSE THEY ARE THE TWO SMALLEST MESSAGING ACTIONS,
/// and they make an instructive pair: one echoes the WHOLE merged map so a screen can
/// adopt it, the other echoes nothing at all so nothing in this client can ever read
/// the value it wrote.
final class MessagingChannelMetaRepositoryTests: XCTestCase {
    // MARK: - Per-channel senders

    /// ⚠️ THE WHOLE MAP COMES BACK, including the channel this request did not
    /// mention, because the route MERGES one key. That is why the response can be
    /// adopted for the channel section without a re-read.
    func testSettingAChannelDefaultCarriesTheChannelAndAdoptsTheMergedMap() async {
        let transport = RepositoryTransport(json: MessagingBodies.channelDefaults)

        let result = await MessagingRepository.testing(transport).setChannelDefault(
            workspaceId: "ws_1",
            channel: "voice",
            accountId: "acct-b"
        )

        XCTAssertEqual(result.successOnly?.channelDefaults, ["sms": "acct-a", "voice": "acct-b"])
        XCTAssertEqual(transport.requests.first?.method, .patch)
        XCTAssertEqual(
            transport.bodies.first,
            #"{"accountId":"acct-b","action":"setChannelDefault","channel":"voice","workspaceId":"ws_1"}"#
        )
    }

    func testAChannelDefaultThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false,"channelDefaults":{}}"#)

        let result = await MessagingRepository.testing(transport).setChannelDefault(
            workspaceId: "ws_1",
            channel: "voice",
            accountId: "acct-b"
        )

        XCTAssertEqual(
            result.failureOnly,
            .decoding("MessagingChannelDefaultResponse did not affirm success=true")
        )
    }

    /// ⚠️ AN UNKNOWN CHANNEL IS A **400 NAMING THE VALUE**, which is worth showing
    /// verbatim: this client does not hold the server's channel list, and refusing
    /// locally would block a channel the server has since added.
    func testAnInvalidChannelAndTheUsualFailuresPassThrough() async {
        let invalid = RepositoryTransport(
            json: #"{"success":false,"error":"Invalid channel: telepathy"}"#,
            status: 400
        )
        let rejected = await MessagingRepository.testing(invalid).setChannelDefault(
            workspaceId: "ws_1",
            channel: "telepathy",
            accountId: "acct-b"
        )
        XCTAssertEqual(rejected.failureOnly, .http(status: 400, message: "Invalid channel: telepathy"))

        let viewer = RepositoryTransport(json: MessagingBodies.forbidden, status: 403)
        let refused = await MessagingRepository.testing(viewer).setChannelDefault(
            workspaceId: "ws_1",
            channel: "voice",
            accountId: "acct-b"
        )
        XCTAssertEqual(refused.failureOnly?.httpStatus, 403)

        let expired = RepositoryTransport(json: MessagingBodies.unauthorized, status: 401)
        let unauthorized = await MessagingRepository.testing(expired).setChannelDefault(
            workspaceId: "ws_1",
            channel: "voice",
            accountId: "acct-b"
        )
        XCTAssertEqual(unauthorized.failureOnly?.isUnauthorized, true)

        let degraded = RepositoryTransport(json: MessagingBodies.degraded, status: 503)
        let transient = await MessagingRepository.testing(degraded).setChannelDefault(
            workspaceId: "ws_1",
            channel: "voice",
            accountId: "acct-b"
        )
        XCTAssertEqual(transient.failureOnly?.httpStatus, 503)
    }

    // MARK: - The creator cell number

    /// ⚠️ ITS OWN ACTION, `meta`, because a workspace with no carrier account has no
    /// upsert to carry the field and is exactly the workspace most likely to be
    /// setting it.
    func testSavingTheCreatorCellUsesTheMetaAction() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await MessagingRepository.testing(transport).saveCreatorCell(
            workspaceId: "ws_1",
            creatorCellNumber: "+14165550170"
        )

        XCTAssertNil(result.failureOnly, "a bare success is the whole answer this action gives")
        XCTAssertEqual(transport.requests.first?.method, .patch)
        XCTAssertEqual(
            transport.bodies.first,
            #"{"action":"meta","creatorCellNumber":"+14165550170","workspaceId":"ws_1"}"#
        )
    }

    func testAMetaWriteThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false}"#)

        let result = await MessagingRepository.testing(transport).saveCreatorCell(
            workspaceId: "ws_1",
            creatorCellNumber: "+14165550170"
        )

        XCTAssertEqual(
            result.failureOnly,
            .decoding("MessagingMetaResponse did not affirm success=true")
        )
    }

    /// ⚠️ A 400 HERE IS "Nothing to update", the route refusing an empty meta write
    /// rather than a permission problem.
    func testAnEmptyMetaWriteAndTheUsualFailuresPassThrough() async {
        let empty = RepositoryTransport(
            json: #"{"success":false,"error":"Nothing to update"}"#,
            status: 400
        )
        let refusedEmpty = await MessagingRepository.testing(empty).saveCreatorCell(
            workspaceId: "ws_1",
            creatorCellNumber: ""
        )
        XCTAssertEqual(refusedEmpty.failureOnly, .http(status: 400, message: "Nothing to update"))

        let viewer = RepositoryTransport(json: MessagingBodies.forbidden, status: 403)
        let refused = await MessagingRepository.testing(viewer).saveCreatorCell(
            workspaceId: "ws_1",
            creatorCellNumber: "+14165550170"
        )
        XCTAssertEqual(refused.failureOnly?.httpStatus, 403)

        let expired = RepositoryTransport(json: MessagingBodies.unauthorized, status: 401)
        let unauthorized = await MessagingRepository.testing(expired).saveCreatorCell(
            workspaceId: "ws_1",
            creatorCellNumber: "+14165550170"
        )
        XCTAssertEqual(unauthorized.failureOnly?.isUnauthorized, true)

        let degraded = RepositoryTransport(json: MessagingBodies.degraded, status: 503)
        let transient = await MessagingRepository.testing(degraded).saveCreatorCell(
            workspaceId: "ws_1",
            creatorCellNumber: "+14165550170"
        )
        XCTAssertEqual(transient.failureOnly?.httpStatus, 503)
    }
}
