import Foundation

// The scheduling admin's event-type row, and the list envelope eight of the
// catalog's reads answer inside ``SchedulingAdminSuccess``.
//
// ⛔ IN `DistrictModel` FOR THE REASON `SchedulingOverrideCreated.swift` STATES:
// `ContractFixtureTests` depends on `ContractGateSupport` and `DistrictModel` and
// nothing else, so a wire type declared beside its repository is a wire type
// `StrictDecodeVerifier` cannot pin.
//
// ⚠️ SNAKE_CASE ON THE WIRE THROUGHOUT, AND EVERY KEY IS SPELLED OUT RATHER THAN
// CONVERTED. These rows pass THROUGH our RPC from a scheduler fork that is not
// ours; every other DTO in this package mirrors a Distronode route and is
// camelCase. ⛔ Reaching for `.convertFromSnakeCase` on the shared decoder to
// "fix" it would re-map the whole District surface to chase this one family —
// ``ApiClient`` uses a plain `JSONDecoder` for every route in the client.

// ⛔ ``SchedulingItems`` IS **NOT** DECLARED HERE. The catalog's
// `items = (schema) => z.object({ items: z.array(schema) })` wrapper is shared
// across namespaces, and it is declared once in `SchedulingAdminDeveloper.swift`.
// A second copy beside the event types would not be a tidier home for it — two
// types of one name in one module do not compile, and the near-miss (a
// `SchedulingEventTypeList` sitting beside a `SchedulingItems`) would give this
// one family a private envelope that drifts from the one every other list uses.
// ⚠️ Its doc there also records the exception worth knowing: `recordings.list` and
// `recordings.consent` declare their `items` key by hand and must not be read
// through it.

/// One bookable event type, as the scheduler serves it.
///
/// ⛔ THIRTY-THREE FIELDS, AND THE TWO THAT ARE MISSING ARE MISSING ON PURPOSE.
/// The fork returns `price_cents` and `currency`; `admin-ops.ts` strips both from
/// the response schema and REFUSES them on the way in, because a dashboard that
/// rendered them would be advertising paid bookings — a feature this platform
/// does not sell to a tenant and cannot settle money for. Adding either here
/// would not make them arrive; it would make this type disagree with the
/// allowlist that governs what does.
///
/// ⛔ THREE DIFFERENT KINDS OF ABSENCE LIVE ON THIS ROW AND THEY ARE NOT
/// INTERCHANGEABLE. `id`, `slug`, `name` and `duration_minutes` are always
/// present. A second group (`slot_interval_minutes`, the four `buffer`/`notice`/
/// `max` numbers, the three flags, `created_at`, `routing_mode`, `rr_strategy`,
/// `archived`, `owned` and the two `owner_*` fields) is OPTIONAL on the wire —
/// the key is absent, not null, because the fork marshals them with `omitempty`
/// or the handler does not join the owner at all. The third group (`description`,
/// `location_value`, the five `msg_*`, the four `subj_*` and `reminders`) arrives
/// as an EXPLICIT NULL: those are nullable columns and Go marshals a nil without
/// `omitempty`. Swift spells all three `Optional`, which is why the contract gate
/// carries per-path null permission rather than a per-type waiver — see
/// `AllowedExplicitNulls+SchedulingA.swift`.
///
/// ⚠️ `location_value` IS POLYMORPHIC AND THE TYPE CANNOT SAY SO. The same column
/// holds a URL for `link` and `custom_video`, a phone number for `phone`, a
/// street address for `in_person`, and nothing at all for the three the scheduler
/// generates itself. Read it through ``SchedulingLocationType`` rather than
/// guessing from the string.
public struct SchedulingEventType: Codable, Equatable, Sendable {
    public let id: String
    public let slug: String
    public let name: String
    /// ⚠️ NULLABLE, NOT ABSENT.
    public let description: String?
    public let durationMinutes: Int
    public let slotIntervalMinutes: Int?
    /// ⚠️ A RAW STRING, NOT ``SchedulingLocationType``. The fork's own CHECK
    /// constraint is wider than the catalog's allowlist (it accepts `zoom`), so a
    /// row can legitimately carry a value this build does not offer — and a
    /// non-optional enum here would fail the whole read rather than the one field.
    public let locationType: String?
    /// ⚠️ NULLABLE, and polymorphic. See the type doc.
    public let locationValue: String?
    public let routingMode: String?
    public let rrStrategy: String?
    public let bufferBeforeMinutes: Int?
    public let bufferAfterMinutes: Int?
    public let minNoticeMinutes: Int?
    public let maxFutureDays: Int?
    public let maxActiveBookings: Int?
    public let isActive: Bool?
    public let showTakenSlots: Bool?
    public let isPublic: Bool?
    public let createdAt: String?
    /// ⚠️ THE FIVE `msg_*` AND FOUR `subj_*` FIELDS ARE ALL NULLABLE, and a null
    /// means "the scheduler's own default", not "no message is sent". A screen
    /// that rendered an empty box for them would be telling an operator their
    /// confirmation email is blank when it is not.
    public let msgConfirmation: String?
    public let msgCancellation: String?
    public let msgReschedule: String?
    public let msgReminder: String?
    public let msgGreeting: String?
    public let subjConfirmation: String?
    public let subjCancellation: String?
    public let subjReschedule: String?
    public let subjReminder: String?
    /// Minutes before the booking at which each reminder is sent.
    ///
    /// ⚠️ NULL RATHER THAN `[]` WHEN UNSET: the fork declares it `[]int` with no
    /// `omitempty`, so a nil slice marshals as `null`. ⛔ And null is NOT the same
    /// as an empty array here — an empty array is "the operator turned every
    /// reminder off", which the patch op can set and the read must not conflate
    /// with "never configured".
    public let reminders: [Int]?
    public let archived: Bool?
    /// Whether the CALLING member owns this event type.
    ///
    /// ⚠️ ABSENT ON A LIST SERVED TO A MEMBER THE HANDLER DID NOT RESOLVE, which
    /// is not the same as `false`. The two `owner_*` fields travel with it.
    public let owned: Bool?
    public let ownerName: String?
    public let ownerEmail: String?

    enum CodingKeys: String, CodingKey {
        case id
        case slug
        case name
        case description
        case durationMinutes = "duration_minutes"
        case slotIntervalMinutes = "slot_interval_minutes"
        case locationType = "location_type"
        case locationValue = "location_value"
        case routingMode = "routing_mode"
        case rrStrategy = "rr_strategy"
        case bufferBeforeMinutes = "buffer_before_minutes"
        case bufferAfterMinutes = "buffer_after_minutes"
        case minNoticeMinutes = "min_notice_minutes"
        case maxFutureDays = "max_future_days"
        case maxActiveBookings = "max_active_bookings"
        case isActive = "is_active"
        case showTakenSlots = "show_taken_slots"
        case isPublic = "is_public"
        case createdAt = "created_at"
        case msgConfirmation = "msg_confirmation"
        case msgCancellation = "msg_cancellation"
        case msgReschedule = "msg_reschedule"
        case msgReminder = "msg_reminder"
        case msgGreeting = "msg_greeting"
        case subjConfirmation = "subj_confirmation"
        case subjCancellation = "subj_cancellation"
        case subjReschedule = "subj_reschedule"
        case subjReminder = "subj_reminder"
        case reminders
        case archived
        case owned
        case ownerName = "owner_name"
        case ownerEmail = "owner_email"
    }
}
