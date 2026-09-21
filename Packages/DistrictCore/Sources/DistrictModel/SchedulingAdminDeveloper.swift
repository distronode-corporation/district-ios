import Foundation

// The Developer tab's rows: API keys, connected OAuth apps, webhooks and their
// delivery log.
//
// ⚠️ SNAKE_CASE ON THE WIRE and `Codable` rather than `Decodable`, for the
// reasons `SchedulingAdminSettings.swift` states at length.

/// The catalog's `items(...)` container, which four of these ops share.
///
/// ⛔ GENERIC RATHER THAN FOUR NEAR-IDENTICAL WRAPPERS, BUT ⚠️ IT IS NOT THE
/// UNIVERSAL LIST ENVELOPE ON THIS SURFACE. `admin-ops.ts` defines
/// `items = (schema) => z.object({ items: z.array(schema) })` and uses it for
/// `apiKeys.list`, `oauth.connections.list`, `webhooks.list` and
/// `webhooks.deliveries` — while `recordings.list` and `recordings.consent`
/// declare their own key by hand. Reaching for this on one of those two throws a
/// missing-key error that reads like an outage; see ``SchedulingRecordingList``.
public struct SchedulingItems<Item: Codable & Sendable>: Codable, Sendable {
    public let items: [Item]
}

extension SchedulingItems: Equatable where Item: Equatable {}

/// One API key, as the list shows it.
///
/// ⛔ NO SECRET HERE, EVER. The plaintext exists exactly once, in the create
/// response (``SchedulingAPIKeyCreated``), and the fork does not send it on the
/// list either. A property for it on this type would be a key that can never
/// arrive and an invitation to persist one.
public struct SchedulingAPIKey: Codable, Equatable, Sendable {
    public let id: String
    /// The customer's own label for it (`Zapier`).
    public let name: String
    public let createdAt: String?
    /// ⛔ NULLABLE ON THE WIRE, NOT ABSENT, AND THE DIFFERENCE DECIDES THE CELL.
    /// The fork scans it into a `*string` and marshals a JSON `null` for a key
    /// that has never been used, and the catalog types it `.nullable().optional()`
    /// — so this Optional covers both spellings and "never used" is the meaning of
    /// nil. ⚠️ It carries an entry in the explicit-null register for exactly this
    /// reason; an `=== undefined` style check on the far side renders the string
    /// "null" into the cell, which is the bug `developer-format.ts` records.
    public let lastUsedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
    }
}

/// The one and only sight of a minted key's plaintext.
///
/// ⛔ `key` IS THE CREDENTIAL AND IT IS RETURNED ONCE. It is in the catalog's
/// allowlist deliberately — the op exists so a customer can mint a key for their
/// OWN integrations, and a mint that never shows the key is useless — but that
/// makes this the one DTO on the surface a client must not log, must not persist
/// and must not interpolate into a copyable snippet. The web console holds it in
/// a modal and drops it from state when the modal closes; anything native should
/// do the same.
///
/// ⚠️ A SEPARATE TYPE FROM ``SchedulingAPIKey`` RATHER THAN AN OPTIONAL FIELD ON
/// IT. One type with a `key: String?` would compile at every list call site and
/// would make "is the secret here" a runtime question asked in the UI layer;
/// two types make it a compile-time one asked once.
public struct SchedulingAPIKeyCreated: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// ⛔ THE PLAINTEXT. See the type note.
    public let key: String
    public let createdAt: String?
    /// The fork's own warning sentence ("Store this now; it is not shown again.").
    /// ⚠️ ENGLISH FROM A SERVICE THAT DOES NOT LOCALISE. Render the app's own copy
    /// and treat this as a fallback, not as a string to translate.
    public let note: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case key
        case createdAt = "created_at"
        case note
    }
}

/// A third-party app holding an OAuth grant on this tenancy.
///
/// ⚠️ NOT AN API KEY, THOUGH THE TWO TABS LOOK ALIKE. A key is minted BY the
/// customer and revoked by deleting it; a connection is granted TO an app by a
/// person consenting, and deleting it signs that app out. The only shared
/// vocabulary is ``lastUsedAt``.
public struct SchedulingOAuthConnection: Codable, Equatable, Sendable {
    public let id: String
    /// The app's self-declared name (`Raycast`). ⛔ UNTRUSTED TEXT: it is whatever
    /// the client registered, so it is a label to show and never an identity to
    /// authorise against.
    public let clientName: String
    public let createdAt: String?
    /// ⛔ NULLABLE ON THE WIRE. See ``SchedulingAPIKey/lastUsedAt``.
    public let lastUsedAt: String?
    /// ⛔ NULLABLE, AND nil MEANS "DOES NOT EXPIRE" RATHER THAN "EXPIRED". A
    /// screen that read nil as lapsed would tell a customer a working integration
    /// is dead. ⚠️ Both nulls appear together on row 1 of the fixture and both
    /// carry an entry in the explicit-null register.
    public let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case clientName = "client_name"
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
        case expiresAt = "expires_at"
    }
}

/// The seven events a webhook may subscribe to.
///
/// ⛔ A CLOSED SET AT THE FAR END, AND A NAME THIS ENUM GETS WRONG IS A HARD
/// **400** (`unknown event: <name>`) ON CREATE **AND** ON PATCH — not an ignored
/// key. Copied from `validWebhookEvents` in the fork's `webhook_handler.go`, which
/// `webhooks.create`'s `z.enum` and `WEBHOOK_EVENTS` in `developer-format.ts` also
/// copy. ⚠️ Three hand-kept copies of one list is deliberate: deriving any of them
/// from another needs a cast that hides a divergence, and a divergence here is a
/// refusal the customer cannot act on.
///
/// ⛔ THIS TYPE IS FOR THE REQUEST SIDE ONLY AND ``SchedulingWebhook/events`` IS
/// DELIBERATELY `[String]`. The RESPONSE schema types the array `z.string()` with
/// no enum, so a row created before an event was renamed — or by some other
/// client — can legitimately carry a value this enum does not have, and a
/// throwing decode there would take out the whole webhooks tab over one stale
/// row. Strict on the way out, lenient on the way in.
public enum SchedulingWebhookEvent: String, Codable, Equatable, Sendable, CaseIterable {
    case bookingCreated = "booking.created"
    case bookingCancelled = "booking.cancelled"
    case bookingRescheduled = "booking.rescheduled"
    case bookingReminder = "booking.reminder"
    case recordingCompleted = "recording.completed"
    case transcriptReady = "transcript.ready"
    case notesReady = "notes.ready"
}

/// One configured webhook.
///
/// ⛔ NO `secret` ON THE LIST, AND THE FORK DOES NOT SEND ONE. It is minted once,
/// on create — see ``SchedulingWebhookCreated``. Same rule as the API keys.
public struct SchedulingWebhook: Codable, Equatable, Sendable {
    public let id: String
    /// ⚠️ `https://` only, enforced by the route rather than by the fork, which
    /// accepts `http` too. A delivery carries names, email addresses and whatever
    /// the booker typed into the intake questions; offering to send that in the
    /// clear is not a choice this platform puts in front of a customer.
    public let url: String
    /// ⚠️ `[String]`, NOT `[SchedulingWebhookEvent]`. See the ⛔ on that enum.
    public let events: [String]
    /// Which payload fields are delivered. ⛔ NULLABLE ON THE WIRE, AND nil MEANS
    /// "THE FORK'S DEFAULT SET", NOT "NONE". A row created before field selection
    /// existed has no list, and the fork substitutes its own `defaultFields` at
    /// delivery time — so a screen that rendered nil as an empty selection would
    /// show every box unticked for a webhook that is sending data. ⚠️ Row 1 of
    /// the fixture carries the explicit null, with an entry in the register.
    public let fields: [String]?
    /// ⚠️ Absent on a fork that predates the column; treat absence as active,
    /// because a row that is not sending would not be in this list at all.
    public let isActive: Bool?
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case url
        case events
        case fields
        case isActive = "is_active"
        case createdAt = "created_at"
    }
}

/// The create response: a webhook plus its signing secret, shown once.
///
/// ⛔ A SEPARATE TYPE RATHER THAN `SchedulingWebhook` WITH AN OPTIONAL `secret`,
/// for the reason ``SchedulingAPIKeyCreated`` gives: making "is the secret here"
/// a compile-time question asked once beats making it a runtime question asked in
/// every cell. The catalog spells this `webhookSchema.extend({secret})`; Swift has
/// no extension for structs, and a composed `webhook: SchedulingWebhook` member
/// would nest the keys one level deeper than the wire does and fail the gate.
///
/// ⚠️ `secret` IS `.optional()` IN THE SCHEMA, so a fork that does not mint one
/// still parses. nil means "no secret to show", never "the webhook was not
/// created".
public struct SchedulingWebhookCreated: Codable, Equatable, Sendable {
    public let id: String
    public let url: String
    public let events: [String]
    public let fields: [String]?
    public let isActive: Bool?
    public let createdAt: String?
    /// ⛔ THE SIGNING SECRET, SHOWN ONCE. Never log it, never persist it.
    public let secret: String?

    enum CodingKeys: String, CodingKey {
        case id
        case url
        case events
        case fields
        case isActive = "is_active"
        case createdAt = "created_at"
        case secret
    }
}

/// One delivery attempt, as the log shows it.
///
/// ⛔ A `failed` WITH NO ``responseStatus`` IS A DIFFERENT FACT FROM A REJECTION,
/// AND THE ROW CANNOT SAY SO ANY OTHER WAY. The worker writes `status = 'failed'`
/// for two unrelated reasons: the endpoint answered outside 2xx (and
/// ``responseStatus`` holds what it said), or the request never got an answer at
/// all (the field is never written). Rendering both as "failed" sends somebody
/// debugging a dead endpoint to read an access log for a request that never
/// arrived.
///
/// ⚠️ THERE IS NO ERROR TEXT ANYWHERE TO SHOW, AND THAT IS NOT AN OMISSION HERE.
/// Neither the fork's `Delivery` struct nor the catalog's schema carries a
/// message; the transport error is logged on the scheduler and dropped.
public struct SchedulingWebhookDelivery: Codable, Equatable, Sendable {
    public let id: String
    public let webhookId: String
    /// The event that triggered it. A `String` for ``SchedulingWebhook/events``'
    /// reason: a delivery logged before a rename outlives the vocabulary.
    public let event: String
    /// `delivered`, `pending`, `failed`, and whatever the fork adds.
    public let status: String
    /// How many times it has been tried, including the first. ⚠️ Required — a
    /// delivery row always has at least one attempt.
    public let attemptCount: Int
    /// ⚠️ Absent on a delivery not bound to a booking (a `recording.completed`
    /// for a recording whose booking is gone).
    public let bookingId: String?
    /// ⛔ ABSENT MEANS NO ANSWER CAME BACK. See the type note.
    public let responseStatus: Int?
    public let lastAttemptedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case webhookId = "webhook_id"
        case event
        case status
        case attemptCount = "attempt_count"
        case bookingId = "booking_id"
        case responseStatus = "response_status"
        case lastAttemptedAt = "last_attempted_at"
    }
}
