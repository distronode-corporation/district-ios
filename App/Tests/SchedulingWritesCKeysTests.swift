@testable import DistrictAI
import DistrictData
import DistrictModel
import XCTest

/// API keys and connected apps, asserted on the op name and the bytes.
///
/// ⛔ THE OP IS A STRING ON THE WIRE AND NOTHING TYPED GUARDS IT. `perform` takes
/// the response type from the CALLER, so naming the wrong op is a runtime decode
/// error rather than a compile error — which means the only proof that a sheet
/// sends `apiKeys.delete` and not `oauth.connections.delete` is reading it back out
/// of the request body.
@MainActor
final class SchedulingWritesCKeysTests: XCTestCase {
    // MARK: - Minting

    func test_IOS_SCHW_C10_creatingAKeySendsTheTrimmedNameAndShowsThePlaintextOnce() async {
        let transport = SchedulingWritesCTransport([
            .ok(#"{"id":"key_9","name":"Booking sync","key":"sk_live_abc","created_at":null,"note":null}"#),
        ])
        var changed = 0
        let model = SchedulingAPIKeyCreateModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            onChanged: { changed += 1 }
        )
        model.name = "  Booking sync  "
        await model.create()

        XCTAssertEqual(transport.ops, ["apiKeys.create"])
        XCTAssertEqual(transport.calls.first?.string("name"), "Booking sync")
        XCTAssertEqual(model.minted?.key, "sk_live_abc")
        // ⚠️ THE NAME THE SERVER ECHOED, not the one that was typed.
        XCTAssertEqual(model.minted?.name, "Booking sync")
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(model.name, "", "the form must not keep a name it already spent")
    }

    /// ⛔ THE PLAINTEXT LEAVES ON DISMISS AND THERE IS NO SECOND CHANCE. `apiKeys.list`
    /// never carries a secret, so a model that kept one would be holding the only
    /// copy of a live credential for as long as the screen stayed up.
    func test_IOS_SCHW_C11_dismissingTheRevealDropsTheKey() async {
        let transport = SchedulingWritesCTransport([
            .ok(#"{"id":"key_9","name":"Zapier","key":"sk_live_abc"}"#),
        ])
        let model = SchedulingAPIKeyCreateModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            onChanged: {}
        )
        model.name = "Zapier"
        await model.create()
        model.markCopied()
        XCTAssertTrue(model.copied)

        model.dismissMinted()
        XCTAssertNil(model.minted)
        XCTAssertFalse(model.copied)
    }

    /// ⚠️ A BLANK NAME SPENDS NO REQUEST. The catalog would refuse it, and a 400 the
    /// customer cannot act on is a worse answer than a sentence beside the box.
    func test_IOS_SCHW_C12_aBlankNameIsRefusedBeforeAnythingIsSent() async {
        let transport = SchedulingWritesCTransport([])
        let model = SchedulingAPIKeyCreateModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            onChanged: { XCTFail("nothing changed, so nothing may be re-read") }
        )
        model.name = "   "
        await model.create()

        XCTAssertTrue(transport.ops.isEmpty)
        XCTAssertEqual(model.nameError, SchedulingWriteCopyC.keyNameMissing)
        XCTAssertNil(model.minted)
    }

    // MARK: - The two shapes of refusal

    /// ⛔ A SCHEDULER REFUSAL IS A **200** CARRYING `{ok:false}`. It must read as an
    /// outage the customer can retry, never as a successful mint with no key.
    func test_IOS_SCHW_C13_a200FailureEnvelopeIsAnOutageAndOffersARetry() async {
        let transport = SchedulingWritesCTransport([.refusal("instance_unavailable")])
        let model = SchedulingAPIKeyCreateModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            onChanged: { XCTFail("a refused create must not ask for a re-read") }
        )
        model.name = "Zapier"
        await model.create()

        XCTAssertNil(model.minted)
        XCTAssertEqual(model.failure?.message, SchedulingFailureCopy.unavailable)
        XCTAssertEqual(model.failure?.action, .retry)
    }

    /// ⛔ A 403 IS OUR OWN ROUTE REFUSING, AND IT IS NOT RETRYABLE. The role will not
    /// change because the button was pressed again.
    func test_IOS_SCHW_C14_aForbiddenCreateSaysSoAndOffersNoRetry() async {
        let transport = SchedulingWritesCTransport([.refused(status: 403, error: "forbidden")])
        let model = SchedulingAPIKeyCreateModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            onChanged: {}
        )
        model.name = "Zapier"
        await model.create()

        XCTAssertEqual(model.failure?.message, SchedulingFailureCopy.forbidden)
        XCTAssertEqual(model.failure?.action, FailureText.Action.none)
    }

    /// ⚠️ A 409 `scheduling_not_ready` IS NOT A FAULT — somebody has to press Enable
    /// — so it says that rather than offering a retry that cannot help.
    func test_IOS_SCHW_C15_aWorkspaceWithNoTenancyIsToldToSetSchedulingUp() async {
        let transport = SchedulingWritesCTransport([
            .refused(status: 409, error: "scheduling_not_ready"),
        ])
        let model = SchedulingAPIKeyCreateModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            onChanged: {}
        )
        model.name = "Zapier"
        await model.create()

        XCTAssertEqual(model.failure?.message, SchedulingFailureCopy.notReady)
        XCTAssertEqual(model.failure?.action, FailureText.Action.none)
    }

    // MARK: - Revoking

    func test_IOS_SCHW_C16_revokingAKeySendsItsIdToApiKeysDelete() async throws {
        let transport = SchedulingWritesCTransport([.noContent])
        var changed = 0
        let model = SchedulingAPIKeyRevokeModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            onChanged: { changed += 1 }
        )
        let key: SchedulingAPIKey = try SchedulingWritesCRows.decode(SchedulingWritesCRows.apiKey)

        model.ask(key)
        XCTAssertTrue(model.isAsking)
        await model.confirm()

        XCTAssertEqual(transport.ops, ["apiKeys.delete"])
        XCTAssertEqual(transport.calls.first?.string("id"), "key_1")
        XCTAssertFalse(model.isAsking)
        XCTAssertEqual(changed, 1)
        XCTAssertNil(model.failure)
    }

    /// ⚠️ CANCELLING SPENDS NOTHING. The prompt is the only thing that was open.
    func test_IOS_SCHW_C17_cancellingARevokeSendsNothing() async throws {
        let transport = SchedulingWritesCTransport([])
        let model = SchedulingAPIKeyRevokeModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            onChanged: { XCTFail("a cancelled revoke changed nothing") }
        )
        let key: SchedulingAPIKey = try SchedulingWritesCRows.decode(SchedulingWritesCRows.apiKey)

        model.ask(key)
        model.cancel()
        await model.confirm()

        XCTAssertTrue(transport.ops.isEmpty)
        XCTAssertFalse(model.isAsking)
    }

    func test_IOS_SCHW_C18_aFailedRevokeReportsAndLeavesTheListAlone() async throws {
        let transport = SchedulingWritesCTransport([.refusal("unavailable")])
        let model = SchedulingAPIKeyRevokeModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            onChanged: { XCTFail("a failed revoke must not claim the list moved") }
        )
        let key: SchedulingAPIKey = try SchedulingWritesCRows.decode(SchedulingWritesCRows.apiKey)

        model.ask(key)
        await model.confirm()

        XCTAssertEqual(model.failure?.message, SchedulingFailureCopy.unavailable)
    }

    // MARK: - Connected apps

    /// ⛔ A DIFFERENT OP ON A DIFFERENT ROW TYPE, AND THE TWO LISTS LOOK ALIKE. A key
    /// is minted BY the customer; a connection is granted TO an app by a person
    /// consenting. Sending one row's id to the other's op would revoke a stranger.
    func test_IOS_SCHW_C19_revokingAnAppSendsOauthConnectionsDelete() async throws {
        let transport = SchedulingWritesCTransport([.noContent])
        var changed = 0
        let model = SchedulingOAuthConnectionRevokeModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            onChanged: { changed += 1 }
        )
        let app: SchedulingOAuthConnection = try SchedulingWritesCRows
            .decode(SchedulingWritesCRows.oauthConnection)

        model.ask(app)
        await model.confirm()

        XCTAssertEqual(transport.ops, ["oauth.connections.delete"])
        XCTAssertEqual(transport.calls.first?.string("id"), "conn_1")
        XCTAssertEqual(changed, 1)
    }
}
