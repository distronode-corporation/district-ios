import DistrictModel
import Foundation
import XCTest

/// The Developer tab's row DTOs, and the webhook event vocabulary.
///
/// ⛔ INLINE BYTES, FOR THE REASON `SchedulingAdminSettingsTests` GIVES.
final class SchedulingAdminDeveloperTests: XCTestCase {
    private let decoder = JSONDecoder()

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }

    // MARK: - The shared `items` container

    /// ⛔ FOUR OPS SHARE IT AND TWO NEARBY ONES DO NOT. `recordings.list` and
    /// `recordings.consent` declare their key by hand, so the wrong container is a
    /// missing-key error that presents as an outage rather than as a client bug.
    func testTheItemsContainerCarriesRowsAndRefusesAnotherKey() throws {
        let keys = try decode(
            SchedulingItems<SchedulingAPIKey>.self,
            #"{"items":[{"id":"key_1","name":"Zapier"}]}"#
        )
        XCTAssertEqual(keys.items.map(\.id), ["key_1"])
        XCTAssertThrowsError(try decode(
            SchedulingItems<SchedulingAPIKey>.self,
            #"{"recordings":[{"id":"key_1","name":"Zapier"}]}"#
        ))
    }

    /// ⚠️ EQUATABLE ONLY WHEN THE ROW IS, which is what lets a test compare two
    /// decoded pages directly.
    func testTheItemsContainerComparesByItsRows() throws {
        let first = try decode(SchedulingItems<SchedulingAPIKey>.self, #"{"items":[{"id":"k","name":"n"}]}"#)
        let second = try decode(SchedulingItems<SchedulingAPIKey>.self, #"{"items":[{"id":"k","name":"n"}]}"#)
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, try decode(SchedulingItems<SchedulingAPIKey>.self, #"{"items":[]}"#))
    }

    // MARK: - API keys

    /// ⛔ NULL, NOT ABSENT, AND NULL MEANS NEVER USED. The fork scans a `*string`
    /// and marshals a JSON null, so both spellings have to decode to nil and a
    /// screen's test has to be truthiness rather than key presence.
    func testAnUnusedKeyNullsItsLastUseAndAMissingKeyMeansTheSame() throws {
        let nulled = try decode(
            SchedulingAPIKey.self,
            #"{"id":"key_2","name":"Unused","created_at":"2026-09-02T11:00:00Z","last_used_at":null}"#
        )
        XCTAssertNil(nulled.lastUsedAt)
        XCTAssertEqual(nulled.createdAt, "2026-09-02T11:00:00Z")

        let absent = try decode(SchedulingAPIKey.self, #"{"id":"key_3","name":"Fresh"}"#)
        XCTAssertNil(absent.lastUsedAt)
        XCTAssertNil(absent.createdAt)
    }

    func testAUsedKeyCarriesItsLastUse() throws {
        let used = try decode(
            SchedulingAPIKey.self,
            #"{"id":"key_1","name":"Zapier","created_at":"2026-09-01T11:00:00Z","last_used_at":"2026-09-10T08:15:00Z"}"#
        )
        XCTAssertEqual(used.lastUsedAt, "2026-09-10T08:15:00Z")
        XCTAssertEqual(used.name, "Zapier")
    }

    /// ⛔ THE CREATE BODY IS A DIFFERENT TYPE AND `key` IS REQUIRED ON IT. Modelled
    /// as an Optional on ``SchedulingAPIKey`` this would round-trip against the
    /// LIST fixtures too, so the contract gate could not tell the two apart — the
    /// separation is what makes "is the secret here" a compile-time question.
    func testTheCreatedKeyRequiresItsPlaintext() throws {
        let created = try decode(
            SchedulingAPIKeyCreated.self,
            #"""
            {"id":"key_1","name":"Zapier","key":"cno_contract_new_api_key",
             "created_at":"2026-09-01T11:00:00Z","note":"Store this now; it is not shown again."}
            """#
        )
        XCTAssertEqual(created.key, "cno_contract_new_api_key")
        XCTAssertEqual(created.note, "Store this now; it is not shown again.")
        XCTAssertEqual(created.createdAt, "2026-09-01T11:00:00Z")
        XCTAssertThrowsError(try decode(SchedulingAPIKeyCreated.self, #"{"id":"key_1","name":"Zapier"}"#))
    }

    /// ⚠️ THE NOTE AND THE TIMESTAMP ARE BOTH `.optional()`; only the credential is
    /// guaranteed.
    func testTheCreatedKeySurvivesWithoutTheForksNote() throws {
        let created = try decode(SchedulingAPIKeyCreated.self, #"{"id":"k","name":"n","key":"secret"}"#)
        XCTAssertNil(created.note)
        XCTAssertNil(created.createdAt)
    }

    // MARK: - Connected apps

    /// ⛔ BOTH NULLS ON ONE ROW, AND THEY MEAN DIFFERENT THINGS. `last_used_at`
    /// null is "never used"; `expires_at` null is "does NOT expire" — never
    /// "expired". A screen that read the second as lapsed would tell a customer a
    /// working integration is dead.
    func testAnUnusedNonExpiringConnectionNullsBothTimestamps() throws {
        let row = try decode(
            SchedulingOAuthConnection.self,
            #"""
            {"id":"oauth_2","client_name":"Internal script","created_at":"2026-09-04T11:00:00Z",
             "last_used_at":null,"expires_at":null}
            """#
        )
        XCTAssertEqual(row.clientName, "Internal script")
        XCTAssertNil(row.lastUsedAt)
        XCTAssertNil(row.expiresAt)
    }

    func testAConnectionCarriesBothTimestampsWhenItHasThem() throws {
        let row = try decode(
            SchedulingOAuthConnection.self,
            #"""
            {"id":"oauth_1","client_name":"Raycast","created_at":"2026-09-03T11:00:00Z",
             "last_used_at":"2026-09-10T19:00:00Z","expires_at":"2026-10-03T11:00:00Z"}
            """#
        )
        XCTAssertEqual(row.lastUsedAt, "2026-09-10T19:00:00Z")
        XCTAssertEqual(row.expiresAt, "2026-10-03T11:00:00Z")
        XCTAssertEqual(row.createdAt, "2026-09-03T11:00:00Z")
    }

    /// ⚠️ `client_name` IS REQUIRED: a grant nobody can name is not something to
    /// offer a Revoke button beside.
    func testAConnectionWithoutAClientNameIsRefused() {
        XCTAssertThrowsError(try decode(SchedulingOAuthConnection.self, #"{"id":"oauth_3"}"#))
    }

    // MARK: - Webhooks

    /// ⛔ THE SEVEN EVENTS, SPELLED OUT A SECOND TIME RATHER THAN DERIVED FROM
    /// `allCases`. A test that read the enum back would assert the code equals
    /// itself and would pass through any rename — and a rename here is a hard 400
    /// (`unknown event: <name>`) at the fork, not an ignored key. This list is
    /// the fork's `validWebhookEvents`, which the server's `webhooks.create` schema
    /// and its developer-page formatter also copy by hand.
    func testTheWebhookEventVocabularyIsTheForksSevenInItsOwnOrder() {
        XCTAssertEqual(
            SchedulingWebhookEvent.allCases.map(\.rawValue),
            [
                "booking.created",
                "booking.cancelled",
                "booking.rescheduled",
                "booking.reminder",
                "recording.completed",
                "transcript.ready",
                "notes.ready",
            ]
        )
    }

    /// ⚠️ SEVEN, COUNTED RATHER THAN ASSUMED — the same discipline
    /// ``SchedulingAdminOp`` applies to its 75.
    func testTheWebhookEventVocabularyHasExactlySevenEntries() {
        XCTAssertEqual(SchedulingWebhookEvent.allCases.count, 7)
        XCTAssertEqual(SchedulingWebhookEvent(rawValue: "booking.created"), .bookingCreated)
        XCTAssertNil(SchedulingWebhookEvent(rawValue: "booking.updated"))
    }

    /// ⛔ `fields` NULL MEANS "THE FORK'S DEFAULT SET", NOT "NO FIELDS". A webhook
    /// created before field selection existed has no list and the fork substitutes
    /// its own at delivery time, so a screen rendering nil as every box unticked
    /// would show a webhook that IS sending data as one that is not.
    func testAnInactiveWebhookNullsItsFieldsAndStillDecodes() throws {
        let row = try decode(
            SchedulingWebhook.self,
            #"""
            {"id":"wh_2","url":"https://hooks.test/recordings","events":["recording.completed"],
             "fields":null,"is_active":false,"created_at":"2026-09-06T11:00:00Z"}
            """#
        )
        XCTAssertNil(row.fields)
        XCTAssertEqual(row.isActive, false)
        XCTAssertEqual(row.events, ["recording.completed"])
    }

    /// ⚠️ `[]` IS A DIFFERENT ANSWER FROM NULL — a customer who deliberately
    /// unticked everything — and both have to decode.
    func testAWebhookTellsAnEmptyFieldListFromANullOne() throws {
        let row = try decode(
            SchedulingWebhook.self,
            #"{"id":"wh_3","url":"https://hooks.test/x","events":["notes.ready"],"fields":[]}"#
        )
        XCTAssertEqual(row.fields, [])
        XCTAssertNil(row.isActive)
        XCTAssertNil(row.createdAt)
    }

    /// ⛔ `events` IS `[String]` ON THE WAY IN, DELIBERATELY. The RESPONSE schema
    /// carries no enum, so a row created before a rename — or by another client —
    /// can hold a value this app's vocabulary does not have, and a throwing decode
    /// would take out the whole tab over one stale row.
    func testAWebhookDecodesAnEventNameTheVocabularyDoesNotKnow() throws {
        let row = try decode(
            SchedulingWebhook.self,
            #"{"id":"wh_4","url":"https://hooks.test/y","events":["booking.updated"]}"#
        )
        XCTAssertEqual(row.events, ["booking.updated"])
        XCTAssertNil(SchedulingWebhookEvent(rawValue: row.events[0]))
    }

    /// ⛔ THE CREATE BODY IS ITS OWN TYPE FOR ``SchedulingAPIKeyCreated``'s REASON,
    /// and `secret` stays `.optional()` so a fork that mints none still parses.
    func testTheCreatedWebhookCarriesTheOnceOnlySecret() throws {
        let created = try decode(
            SchedulingWebhookCreated.self,
            #"""
            {"id":"wh_1","url":"https://hooks.test/bookings",
             "events":["booking.created","booking.cancelled"],
             "fields":["attendee_name","attendee_email"],"is_active":true,
             "created_at":"2026-09-05T11:00:00Z","secret":"whsec_contract_shown_once"}
            """#
        )
        XCTAssertEqual(created.secret, "whsec_contract_shown_once")
        XCTAssertEqual(created.fields, ["attendee_name", "attendee_email"])
        XCTAssertEqual(created.isActive, true)
        XCTAssertEqual(created.createdAt, "2026-09-05T11:00:00Z")

        let bare = try decode(
            SchedulingWebhookCreated.self,
            #"{"id":"wh_5","url":"https://hooks.test/z","events":["notes.ready"]}"#
        )
        XCTAssertNil(bare.secret)
        XCTAssertNil(bare.fields)
        XCTAssertNil(bare.isActive)
        XCTAssertNil(bare.createdAt)
    }

    // MARK: - Deliveries

    /// ⛔ A `failed` WITH NO `response_status` IS A DIFFERENT FACT FROM A
    /// REJECTION, and the row cannot say so any other way: the worker writes the
    /// same status word for "answered outside 2xx" and "never got an answer".
    func testADeliveryTellsARejectionFromNoAnswer() throws {
        let rejected = try decode(
            SchedulingWebhookDelivery.self,
            #"""
            {"id":"whd_1","webhook_id":"wh_1","event":"booking.created","status":"delivered",
             "attempt_count":1,"booking_id":"bk_1","response_status":200,
             "last_attempted_at":"2026-09-10T09:00:02Z"}
            """#
        )
        XCTAssertEqual(rejected.responseStatus, 200)
        XCTAssertEqual(rejected.bookingId, "bk_1")
        XCTAssertEqual(rejected.webhookId, "wh_1")
        XCTAssertEqual(rejected.attemptCount, 1)
        XCTAssertEqual(rejected.lastAttemptedAt, "2026-09-10T09:00:02Z")

        let unanswered = try decode(
            SchedulingWebhookDelivery.self,
            #"""
            {"id":"whd_2","webhook_id":"wh_1","event":"recording.completed","status":"failed",
             "attempt_count":5,"last_attempted_at":"2026-09-10T09:30:00Z"}
            """#
        )
        XCTAssertNil(unanswered.responseStatus)
        XCTAssertNil(unanswered.bookingId)
        XCTAssertEqual(unanswered.attemptCount, 5)
        XCTAssertEqual(unanswered.event, "recording.completed")
        XCTAssertEqual(unanswered.status, "failed")
    }

    /// ⚠️ `attempt_count` IS REQUIRED. A delivery row always has at least one
    /// attempt, and an Optional there would let a screen render a blank where the
    /// retry count belongs.
    func testADeliveryWithoutAnAttemptCountIsRefused() {
        XCTAssertThrowsError(try decode(
            SchedulingWebhookDelivery.self,
            #"{"id":"whd_3","webhook_id":"wh_1","event":"notes.ready","status":"pending"}"#
        ))
    }
}
