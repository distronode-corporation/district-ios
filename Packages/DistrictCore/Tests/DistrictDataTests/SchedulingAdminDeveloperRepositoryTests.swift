import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The `apiKeys.*`, `oauth.connections.*` and `webhooks.*` repository methods.
///
/// ⛔ THE BODY BYTES ARE ASSERTED ALONGSIDE THE RESULT. Three of these ops take an
/// `id` that is ALSO a path segment at the far end, and the strip happens
/// server-side — so "did the id travel" is a question about the encoded document
/// rather than about the arguments.
final class SchedulingAdminDeveloperRepositoryTests: XCTestCase {
    private func repository(_ transport: RepositoryTransport) -> SchedulingAdminRepository {
        SchedulingAdminRepository(client: .repositoryTest(transport), reportUnknownOp: { _ in })
    }

    private func envelope(_ data: String) -> String {
        #"{"ok":true,"data":\#(data)}"#
    }

    // MARK: - API keys

    func testListingKeysUnwrapsTheSharedItemsContainer() async throws {
        let transport = RepositoryTransport(json: envelope(
            #"{"items":[{"id":"key_1","name":"Zapier","last_used_at":null},{"id":"key_2","name":"Fresh"}]}"#
        ))
        let keys = try await repository(transport).apiKeys(workspaceId: "ws_1")
        XCTAssertEqual(keys.map(\.name), ["Zapier", "Fresh"])
        XCTAssertNil(keys[0].lastUsedAt)
        XCTAssertEqual(transport.bodies, [#"{"op":"apiKeys.list","params":{},"workspaceId":"ws_1"}"#])
    }

    /// ⛔ THE CREATE ANSWERS A DIFFERENT TYPE FROM THE LIST BECAUSE IT CARRIES THE
    /// PLAINTEXT, once. The separation is what makes "is the secret here" a
    /// compile-time question rather than one asked in every cell.
    func testCreatingAKeyReturnsThePlaintextOnce() async throws {
        let transport = RepositoryTransport(json: envelope(
            #"{"id":"key_1","name":"Zapier","key":"cno_new","note":"Store this now."}"#
        ))
        let created = try await repository(transport).createAPIKey(workspaceId: "ws_1", name: "Zapier")
        XCTAssertEqual(created.key, "cno_new")
        XCTAssertEqual(created.note, "Store this now.")
        XCTAssertEqual(
            transport.bodies,
            [#"{"op":"apiKeys.create","params":{"name":"Zapier"},"workspaceId":"ws_1"}"#]
        )
    }

    func testDeletingAKeySendsItsIdAndAnswersNothing() async throws {
        let transport = RepositoryTransport(json: envelope(#"{"ok":true}"#))
        let answer = try await repository(transport).deleteAPIKey(workspaceId: "ws_1", keyId: "key_1")
        XCTAssertTrue(answer.ok)
        XCTAssertEqual(
            transport.bodies,
            [#"{"op":"apiKeys.delete","params":{"id":"key_1"},"workspaceId":"ws_1"}"#]
        )
    }

    // MARK: - Connected apps

    /// ⛔ BOTH TIMESTAMPS NULL ON ONE ROW, AND THEY MEAN DIFFERENT THINGS: never
    /// used, and does NOT expire. Asserted through the repository as well as the
    /// DTO because this is the read a Revoke screen draws from.
    func testListingConnectionsKeepsBothNullTimestamps() async throws {
        let transport = RepositoryTransport(json: envelope(
            #"""
            {"items":[{"id":"oauth_1","client_name":"Raycast","expires_at":"2026-10-03T11:00:00Z"},
                      {"id":"oauth_2","client_name":"Internal script","last_used_at":null,"expires_at":null}]}
            """#
        ))
        let rows = try await repository(transport).oauthConnections(workspaceId: "ws_1")
        XCTAssertEqual(rows.map(\.clientName), ["Raycast", "Internal script"])
        XCTAssertEqual(rows[0].expiresAt, "2026-10-03T11:00:00Z")
        XCTAssertNil(rows[1].expiresAt)
        XCTAssertNil(rows[1].lastUsedAt)
        XCTAssertEqual(transport.bodies, [#"{"op":"oauth.connections.list","params":{},"workspaceId":"ws_1"}"#])
    }

    /// ⚠️ THE OP NAME CARRIES TWO DOTS AND IS THE SERVER'S KEY VERBATIM; a
    /// transliteration slip here is a 400 `unknown_op`, not a compile error.
    func testDeletingAConnectionUsesTheDottedOpName() async throws {
        let transport = RepositoryTransport(json: envelope(#"{"ok":true}"#))
        let answer = try await repository(transport).deleteOAuthConnection(
            workspaceId: "ws_1",
            connectionId: "oauth_2"
        )
        XCTAssertTrue(answer.ok)
        XCTAssertEqual(
            transport.bodies,
            [#"{"op":"oauth.connections.delete","params":{"id":"oauth_2"},"workspaceId":"ws_1"}"#]
        )
    }

    // MARK: - Webhooks

    func testListingWebhooksKeepsTheNullFieldSelection() async throws {
        let transport = RepositoryTransport(json: envelope(
            #"""
            {"items":[{"id":"wh_1","url":"https://hooks.test/a","events":["booking.created"],
                       "fields":["attendee_name"],"is_active":true},
                      {"id":"wh_2","url":"https://hooks.test/b","events":["notes.ready"],"fields":null}]}
            """#
        ))
        let rows = try await repository(transport).webhooks(workspaceId: "ws_1")
        XCTAssertEqual(rows[0].fields, ["attendee_name"])
        XCTAssertNil(rows[1].fields)
        XCTAssertNil(rows[1].isActive)
        XCTAssertEqual(transport.bodies, [#"{"op":"webhooks.list","params":{},"workspaceId":"ws_1"}"#])
    }

    /// ⛔ THE EVENT NAMES LEAVE AS THE ENUM'S RAW VALUES. A name the fork does not
    /// know is a hard 400 rather than an ignored key, so the request side is closed
    /// — and this is the assertion that proves the enum's strings are what travels
    /// rather than its case names.
    func testCreatingAWebhookSendsTheForksEventSpellings() async throws {
        let transport = RepositoryTransport(json: envelope(
            #"{"id":"wh_1","url":"https://hooks.test/a","events":["booking.created"],"secret":"whsec_1"}"#
        ))
        let created = try await repository(transport).createWebhook(
            workspaceId: "ws_1",
            url: "https://hooks.test/a",
            events: [.bookingCreated, .recordingCompleted],
            fields: ["attendee_name", "answers"]
        )
        XCTAssertEqual(created.secret, "whsec_1")
        XCTAssertEqual(
            transport.bodies,
            [
                #"{"op":"webhooks.create","params":{"events":["booking.created","recording.completed"],"#
                    + #""fields":["attendee_name","answers"],"url":"https:\/\/hooks.test\/a"},"#
                    + #""workspaceId":"ws_1"}"#,
            ]
        )
    }

    /// ⛔ OMITTING `fields` IS NOT THE SAME AS SENDING `[]`, AND THE WIRE IS WHERE
    /// THE DIFFERENCE LIVES. nil means "the fork's default set" — which is not the
    /// list the console offers — so a webhook created this way arrives missing
    /// values the form never offered to remove.
    func testCreatingAWebhookWithoutFieldsOmitsTheKeyEntirely() async throws {
        let transport = RepositoryTransport(json: envelope(
            #"{"id":"wh_2","url":"https://hooks.test/b","events":["notes.ready"]}"#
        ))
        _ = try await repository(transport).createWebhook(
            workspaceId: "ws_1",
            url: "https://hooks.test/b",
            events: [.notesReady]
        )
        XCTAssertEqual(
            transport.bodies,
            [
                #"{"op":"webhooks.create","params":{"events":["notes.ready"],"#
                    + #""url":"https:\/\/hooks.test\/b"},"workspaceId":"ws_1"}"#,
            ]
        )
    }

    /// ⚠️ AN EMPTY SELECTION IS A DELIBERATE CHOICE AND TRAVELS AS `[]`.
    func testCreatingAWebhookWithAnEmptyFieldListSendsTheEmptyArray() async throws {
        let transport = RepositoryTransport(json: envelope(
            #"{"id":"wh_3","url":"https://hooks.test/c","events":["notes.ready"]}"#
        ))
        _ = try await repository(transport).createWebhook(
            workspaceId: "ws_1",
            url: "https://hooks.test/c",
            events: [.notesReady],
            fields: []
        )
        XCTAssertEqual(
            transport.bodies,
            [
                #"{"op":"webhooks.create","params":{"events":["notes.ready"],"fields":[],"#
                    + #""url":"https:\/\/hooks.test\/c"},"workspaceId":"ws_1"}"#,
            ]
        )
    }

    /// ⛔ THE PATCH ANSWERS 204 WITH NO BODY, so there is no updated row to render
    /// and a caller must refetch. The `id` still travels in the params.
    func testPatchingAWebhookAnswersNoContentAndCarriesTheId() async throws {
        let transport = RepositoryTransport(json: envelope(#"{"ok":true}"#))
        let answer = try await repository(transport).updateWebhook(
            workspaceId: "ws_1",
            webhookId: "wh_1",
            events: ["booking.cancelled"],
            fields: ["host_name"]
        )
        XCTAssertTrue(answer.ok)
        XCTAssertEqual(
            transport.bodies,
            [
                #"{"op":"webhooks.patch","params":{"events":["booking.cancelled"],"#
                    + #""fields":["host_name"],"id":"wh_1"},"workspaceId":"ws_1"}"#,
            ]
        )
    }

    /// ⚠️ A PATCH THAT CHANGES NOTHING BUT THE ID IS A VALID SPARSE BODY: both
    /// fields are `.optional()` on the schema, so the omitted keys are absent
    /// rather than cleared.
    func testPatchingAWebhookWithNothingSetSendsOnlyTheId() async throws {
        let transport = RepositoryTransport(json: envelope(#"{"ok":true}"#))
        _ = try await repository(transport).updateWebhook(workspaceId: "ws_1", webhookId: "wh_1")
        XCTAssertEqual(
            transport.bodies,
            [#"{"op":"webhooks.patch","params":{"id":"wh_1"},"workspaceId":"ws_1"}"#]
        )
    }

    func testDeletingAWebhookSendsItsId() async throws {
        let transport = RepositoryTransport(json: envelope(#"{"ok":true}"#))
        let answer = try await repository(transport).deleteWebhook(workspaceId: "ws_1", webhookId: "wh_1")
        XCTAssertTrue(answer.ok)
        XCTAssertEqual(
            transport.bodies,
            [#"{"op":"webhooks.delete","params":{"id":"wh_1"},"workspaceId":"ws_1"}"#]
        )
    }

    /// ⛔ THE DELIVERY LOG'S TWO `failed` SHAPES SURVIVE THE REPOSITORY. A row with
    /// no `response_status` means nobody answered, which is a different fact from a
    /// rejection and the only way the row can say so.
    func testDeliveriesKeepTheDifferenceBetweenARejectionAndNoAnswer() async throws {
        let transport = RepositoryTransport(json: envelope(
            #"""
            {"items":[{"id":"whd_1","webhook_id":"wh_1","event":"booking.created","status":"delivered",
                       "attempt_count":1,"response_status":200},
                      {"id":"whd_2","webhook_id":"wh_1","event":"notes.ready","status":"failed",
                       "attempt_count":5}]}
            """#
        ))
        let rows = try await repository(transport).webhookDeliveries(workspaceId: "ws_1", webhookId: "wh_1")
        XCTAssertEqual(rows[0].responseStatus, 200)
        XCTAssertNil(rows[1].responseStatus)
        XCTAssertEqual(rows[1].attemptCount, 5)
        XCTAssertEqual(
            transport.bodies,
            [#"{"op":"webhooks.deliveries","params":{"id":"wh_1"},"workspaceId":"ws_1"}"#]
        )
    }

    /// ⛔ A **400 `invalid_params`** CARRIES FIELD NAMES ONLY, never messages — a
    /// zod issue's text quotes the offending input straight back out of the API.
    /// Pinned on the webhook create because its `url` is the field a customer is
    /// most likely to get refused on.
    func testAnInvalidWebhookUrlArrivesAsFieldNamesRatherThanProse() async {
        let transport = RepositoryTransport(
            json: #"{"error":"invalid_params","fields":["url"]}"#,
            status: 400
        )
        do {
            _ = try await repository(transport).createWebhook(
                workspaceId: "ws_1",
                url: "http://localhost/hook",
                events: [.notesReady]
            )
            XCTFail("expected a refusal")
        } catch let error as SchedulingAdminError {
            XCTAssertEqual(error, .invalidParams(["url"]))
            XCTAssertEqual(error.uiCode, .unknown)
        } catch {
            XCTFail("expected a SchedulingAdminError, got \(error)")
        }
    }
}
