@testable import DistrictAI
import DistrictData
import DistrictModel
import XCTest

/// Webhooks: the create, the patch, the delete and the delivery log.
///
/// ⛔ THE ORDER OF `events` AND `fields` IS PART OF THE ASSERTION, NOT INCIDENTAL.
/// Both arrays are filtered through a canonical list on the way out so the stored
/// value matches the one every other surface prints; building them from tick order
/// would produce a webhook whose configuration reads differently on each client.
@MainActor
final class SchedulingWritesCWebhookTests: XCTestCase {
    // MARK: - Creating

    func test_IOS_SCHW_C20_creatingSendsTheUrlEventsAndFieldsInTheForksOrder() async {
        let transport = SchedulingWritesCTransport([
            .ok(#"""
            {"id":"wh_9","url":"https://example.com/hooks","events":["booking.created"],
             "fields":["id"],"is_active":true,"created_at":null,"secret":"whsec_abc"}
            """#),
        ])
        var changed = 0
        let model = SchedulingWebhookEditorModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            mode: .create,
            onChanged: { changed += 1 }
        )
        model.draft.url = " https://example.com/hooks "
        // ⚠️ Inserted out of order on purpose: the request must not echo tick order.
        model.draft.events = [.notesReady, .bookingCreated]
        await model.submit()

        let call = transport.calls.first
        XCTAssertEqual(transport.ops, ["webhooks.create"])
        XCTAssertEqual(call?.string("url"), "https://example.com/hooks")
        XCTAssertEqual(call?.strings("events"), ["booking.created", "notes.ready"])
        XCTAssertEqual(model.minted?.secret, "whsec_abc")
        XCTAssertEqual(changed, 1)
    }

    /// ⛔ THE ATTENDEE'S OWN DETAILS ARE OFF BY DEFAULT AND EVERYTHING ELSE IS ON. A
    /// webhook is a copy of a booking leaving this platform for a system we know
    /// nothing about; sending a stranger's name and address should be a tick
    /// somebody made.
    func test_IOS_SCHW_C21_aNewWebhookSendsEveryFieldExceptTheAttendeesOwn() async {
        let transport = SchedulingWritesCTransport([
            .ok(#"""
            {"id":"wh_9","url":"https://example.com/h","events":["booking.created"],
             "fields":null,"is_active":true,"created_at":null,"secret":null}
            """#),
        ])
        let model = SchedulingWebhookEditorModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            mode: .create,
            onChanged: {}
        )
        model.draft.url = "https://example.com/h"
        model.draft.events = [.bookingCreated]
        await model.submit()

        let fields = transport.calls.first?.strings("fields") ?? []
        XCTAssertFalse(fields.contains("attendee_email"))
        XCTAssertFalse(fields.contains("answers"))
        XCTAssertTrue(fields.contains("host_email"), "the host is the customer's own staff")
        XCTAssertTrue(fields.contains("event_type_name"))
        // ⚠️ A CREATE WITH NO SECRET IS STILL A SUCCESSFUL CREATE: `secret` is
        // optional on the response schema, so nil means "nothing to show once".
        XCTAssertNil(model.minted)
        XCTAssertEqual(model.savedNotice, SchedulingWriteCopyC.webhookAdded)
    }

    /// ⛔ FIELDS GO OUT IN THE CANONICAL ORDER, NOT IN SET ORDER. A `Set` has no
    /// order at all, so this is the assertion that proves the filter is what builds
    /// the array.
    func test_IOS_SCHW_C22_theFieldListIsSentInTheCanonicalOrder() async {
        let transport = SchedulingWritesCTransport([
            .ok(#"""
            {"id":"wh_9","url":"https://example.com/h","events":["booking.created"],
             "fields":null,"is_active":true,"created_at":null,"secret":null}
            """#),
        ])
        let model = SchedulingWebhookEditorModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            mode: .create,
            onChanged: {}
        )
        model.draft.url = "https://example.com/h"
        model.draft.events = [.bookingCreated]
        model.draft.fields = ["answers", "id", "status"]
        await model.submit()

        XCTAssertEqual(transport.calls.first?.strings("fields"), ["id", "status", "answers"])
    }

    // MARK: - Validation

    func test_IOS_SCHW_C23_everyRefusedUrlSpendsNoRequestAndSaysWhy() async {
        let cases: [(String, String)] = [
            ("", SchedulingWriteCopyC.webhookUrlMissing),
            ("example.com/hooks", SchedulingWriteCopyC.webhookUrlNotAUrl),
            ("http://example.com/hooks", SchedulingWriteCopyC.webhookUrlNotHttps),
            ("https://localhost/hooks", SchedulingWriteCopyC.webhookUrlPrivate),
            ("https://192.168.0.4/hooks", SchedulingWriteCopyC.webhookUrlPrivate),
            ("https://172.20.1.1/hooks", SchedulingWriteCopyC.webhookUrlPrivate),
            ("https://box.local/hooks", SchedulingWriteCopyC.webhookUrlPrivate),
        ]
        for (url, expected) in cases {
            let transport = SchedulingWritesCTransport([])
            let model = SchedulingWebhookEditorModel(
                repository: .writesCTest(transport),
                workspaceId: "ws_1",
                mode: .create,
                onChanged: { XCTFail("a refused URL changed nothing") }
            )
            model.draft.url = url
            model.draft.events = [.bookingCreated]
            await model.submit()

            XCTAssertTrue(transport.ops.isEmpty, "\(url) must not reach the wire")
            XCTAssertEqual(model.urlError, expected, "for \(url)")
        }
    }

    /// ⚠️ `172.2.x` IS PUBLIC AND `172.20.x` IS NOT, which is the one private range
    /// that is a range rather than a literal prefix.
    func test_IOS_SCHW_C24_a172AddressOutsideThePrivateRangeIsNotRefused() {
        XCTAssertNil(SchedulingWebhookURLCheckC.issue("https://172.2.3.4/hooks"))
        XCTAssertNotNil(SchedulingWebhookURLCheckC.issue("https://172.31.3.4/hooks"))
    }

    func test_IOS_SCHW_C25_aWebhookWithNoEventIsRefusedBeforeTheWire() async {
        let transport = SchedulingWritesCTransport([])
        let model = SchedulingWebhookEditorModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            mode: .create,
            onChanged: {}
        )
        model.draft.url = "https://example.com/hooks"
        await model.submit()

        XCTAssertTrue(transport.ops.isEmpty)
        XCTAssertEqual(model.eventsError, SchedulingWriteCopyC.webhookEventsMissing)
        XCTAssertFalse(model.canSubmit)
    }

    // MARK: - Editing

    /// ⛔ THE PATCH SENDS NO URL, BECAUSE THE OP TAKES NONE. A key in the body the
    /// schema does not have is a 400 the customer cannot act on.
    func test_IOS_SCHW_C26_anEditSendsEventsAndFieldsAndNeverTheUrl() async throws {
        let transport = SchedulingWritesCTransport([.noContent])
        var changed = 0
        let webhook: SchedulingWebhook = try SchedulingWritesCRows.decode(SchedulingWritesCRows.webhook)
        let model = SchedulingWebhookEditorModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            mode: .edit(webhook),
            onChanged: { changed += 1 }
        )
        model.draft.events.insert(.bookingCancelled)
        await model.submit()

        let call = transport.calls.first
        XCTAssertEqual(transport.ops, ["webhooks.patch"])
        XCTAssertEqual(call?.string("id"), "wh_1")
        XCTAssertNil(call?.string("url"), "webhooks.patch has no url and must not be sent one")
        XCTAssertEqual(call?.strings("events"), ["booking.created", "booking.cancelled"])
        XCTAssertEqual(call?.strings("fields"), ["id", "status"])
        XCTAssertEqual(model.fixedURL, "https://example.com/hooks")
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(model.savedNotice, SchedulingWriteCopyC.webhookUpdated)
    }

    /// ⛔ AN UNKNOWN EVENT IS NAMED RATHER THAN DROPPED IN SILENCE. The form cannot
    /// draw a box for it and the patch cannot send it back, so the sheet says what
    /// a save would stop sending.
    func test_IOS_SCHW_C27_anEventThisBuildDoesNotKnowIsReportedAndNotSent() async throws {
        let transport = SchedulingWritesCTransport([.noContent])
        let webhook: SchedulingWebhook = try SchedulingWritesCRows
            .decode(SchedulingWritesCRows.webhookWithUnknownEvent)
        let model = SchedulingWebhookEditorModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            mode: .edit(webhook),
            onChanged: {}
        )
        XCTAssertEqual(model.droppedEvents, ["booking.moved"])
        await model.submit()

        XCTAssertEqual(transport.calls.first?.strings("events"), ["booking.created"])
    }

    /// ⚠️ AN ABSENT `fields` IS NOT AN EMPTY SELECTION: the fork substitutes its own
    /// default set at delivery time, so opening such a row on an empty form would
    /// claim the webhook sends no data at all.
    func test_IOS_SCHW_C28_aRowWithNoStoredFieldsOpensOnTheDefaultSelection() throws {
        let webhook: SchedulingWebhook = try SchedulingWritesCRows
            .decode(SchedulingWritesCRows.webhookWithUnknownEvent)
        let draft = SchedulingWebhookDraftC.from(webhook)
        XCTAssertEqual(draft.fields, SchedulingWebhookFieldsC.defaults)
        XCTAssertFalse(draft.fields.isEmpty)
    }

    // MARK: - Deleting

    func test_IOS_SCHW_C29_deletingSendsWebhooksDeleteWithTheRowsId() async throws {
        let transport = SchedulingWritesCTransport([.noContent])
        var changed = 0
        let webhook: SchedulingWebhook = try SchedulingWritesCRows.decode(SchedulingWritesCRows.webhook)
        let model = SchedulingWebhookDeleteModel(
            repository: .writesCTest(transport),
            workspaceId: "ws_1",
            onChanged: { changed += 1 }
        )
        model.ask(webhook)
        await model.confirm()

        XCTAssertEqual(transport.ops, ["webhooks.delete"])
        XCTAssertEqual(transport.calls.first?.string("id"), "wh_1")
        XCTAssertEqual(changed, 1)
    }
}
