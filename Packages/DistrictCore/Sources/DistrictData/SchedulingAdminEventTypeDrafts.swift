import Foundation

// What `eventTypes.create` and `eventTypes.patch` take, as two types rather than
// one.
//
// ⛔ TWO TYPES BECAUSE THE TWO SCHEMAS ARE NOT NESTED, AND A SINGLE "ALL FIELDS
// OPTIONAL" TYPE WOULD BE A LIE IN BOTH DIRECTIONS. `create` REQUIRES `slug`,
// `name` and `duration_minutes` and accepts fourteen fields in total; `patch`
// requires only the slug it is addressed by and accepts twenty-eight, fourteen of
// which `create` refuses outright — `rr_strategy`, `is_active`, `is_public`,
// `archived`, the five `msg_*`, the four `subj_*` and `reminders`. Sharing one
// type would offer a create form fourteen controls whose every use is a **400
// `invalid_params`** naming a field the operator was invited to fill in.
//
// ⛔ AND NOTHING HERE VALIDATES. The catalog's zod schema is the only validator and
// it runs server-side; a second, laxer copy on this side would refuse bodies the
// server accepts (a client bug nobody can work around) or accept bodies it rejects
// (a 400 the user cannot act on). See the ⛔ on ``SchedulingAdminRepository``.
// ⚠️ That is also why the enum-valued fields below are `String` rather than Swift
// enums. ``SchedulingLocationType`` is pinned because it decides what
// `location_value` MEANS, which is a question this client has to answer on screen;
// `routing_mode`, `rr_strategy` and the rest decide nothing here, and an enum for
// each would be four more literals that can silently disagree with the server.
//
// ⚠️ `var` WITH A `nil` DEFAULT, NOT A THIRTY-PARAMETER INITIALISER, and the
// reason is the wire rather than taste: `JSONValue.object(_:)` DROPS a nil pair,
// so "left alone" and "not mentioned" are the same thing and a builder reads as
// what it is. `RoutingRuleDraft` is the same shape for the same reason.

/// A new event type, as `eventTypes.create` takes it.
///
/// ⛔ `slug` IS PERMANENT-ISH AND PUBLIC. It is the last segment of the booking
/// page's URL, so it is the half of this draft an attendee sees; `patch` can change
/// it, and doing so breaks every link already shared.
///
/// ⚠️ FOURTEEN FIELDS AND NOT SIXTEEN: `price_cents` and `currency` are REFUSED by
/// the catalog rather than merely absent from it (`refuseEventTypeExtras`), because
/// a tenancy that believed it was charging for consultations would not be. There is
/// nothing to add here the day the platform sells them — the server has to change
/// first.
public struct SchedulingEventTypeDraft: Sendable, Equatable {
    public var slug: String
    public var name: String
    public var durationMinutes: Int
    public var description: String?
    public var slotIntervalMinutes: Int?
    /// ⚠️ One of ``SchedulingLocationType``'s seven raw values. See the ⚠️ at the
    /// head of this file.
    public var locationType: String?
    /// ⛔ REFUSED WHEN IT IS NOT A URL **AND** `locationType` IS `link` or
    /// `custom_video` **AND** BOTH ARE SENT. The check is conditional at both ends;
    /// read ``SchedulingLocationType/valueKind`` before offering a field for it.
    public var locationValue: String?
    /// `fixed`, `round_robin` or `collective`.
    public var routingMode: String?
    public var bufferBeforeMinutes: Int?
    public var bufferAfterMinutes: Int?
    public var minNoticeMinutes: Int?
    public var maxFutureDays: Int?
    public var maxActiveBookings: Int?
    public var showTakenSlots: Bool?

    /// ⚠️ THE THREE THE SCHEMA REQUIRES, AND NOTHING ELSE. Every other field is a
    /// `var` the caller sets, so a create that sends only these three is a
    /// deliberate minimum rather than an oversight.
    public init(slug: String, name: String, durationMinutes: Int) {
        self.slug = slug
        self.name = name
        self.durationMinutes = durationMinutes
    }
}

/// The fields `eventTypes.patch` may change, all of them optional.
///
/// ⛔ nil IS "LEAVE ALONE", NOT "CLEAR". Every pair here is dropped from the body
/// when nil, so there is no way through this type to null a column — which is the
/// correct default for a sparse patch and is also a limitation worth knowing:
/// clearing a custom confirmation message back to the scheduler's default is not
/// something the catalog's schema expresses at all (the fields are
/// `z.string().optional()`, not `.nullable()`), so it is not a gap this type can
/// close on its own.
///
/// ⚠️ `slug` IS ABSENT FROM THIS TYPE AND PRESENT IN THE BODY. It is the op's path
/// key, taken as its own argument by
/// ``SchedulingAdminRepository/patchEventType(workspaceId:slug:changes:)`` because
/// it addresses the row; the server's schema requires it in `params` as well and
/// strips it after validating, so the repository puts it back. ⛔ A rename is
/// therefore NOT expressible here on purpose — the schema's `slug` is the address,
/// and sending a different one would read as "rename" to a caller and as "patch a
/// row that does not exist" to the server.
public struct SchedulingEventTypeChanges: Sendable, Equatable {
    public var name: String?
    public var description: String?
    public var durationMinutes: Int?
    public var slotIntervalMinutes: Int?
    /// ⚠️ One of ``SchedulingLocationType``'s seven raw values.
    public var locationType: String?
    /// ⛔ Conditionally refused. See ``SchedulingEventTypeDraft/locationValue``.
    public var locationValue: String?
    /// `fixed`, `round_robin` or `collective`.
    public var routingMode: String?
    /// `even`, `soonest` or `priority`. ⚠️ CREATE CANNOT SET THIS; a round-robin
    /// event type is created and then patched.
    public var rrStrategy: String?
    public var bufferBeforeMinutes: Int?
    public var bufferAfterMinutes: Int?
    public var minNoticeMinutes: Int?
    public var maxFutureDays: Int?
    public var maxActiveBookings: Int?
    public var isActive: Bool?
    public var isPublic: Bool?
    public var showTakenSlots: Bool?
    /// ⚠️ ARCHIVING IS A PATCH, NOT `eventTypes.delete`. The delete op removes the
    /// row; this hides it while leaving its bookings addressable, which is what an
    /// operator almost always means.
    public var archived: Bool?
    public var msgConfirmation: String?
    public var msgCancellation: String?
    public var msgReschedule: String?
    public var msgReminder: String?
    public var msgGreeting: String?
    public var subjConfirmation: String?
    public var subjCancellation: String?
    public var subjReschedule: String?
    public var subjReminder: String?
    /// Minutes before the booking at which each reminder is sent, at most five.
    ///
    /// ⛔ `[]` IS A REAL INSTRUCTION AND IS NOT DROPPED: it turns every reminder
    /// off. nil leaves the schedule alone. The read side spells the third state —
    /// never configured — as `null`, which this type cannot send.
    public var reminders: [Int]?

    /// An empty set of changes.
    ///
    /// ⚠️ SENDING ONE IS A NO-OP PATCH THAT STILL SPENDS A WRITE from the
    /// workspace's hourly budget, because the op is a write regardless of what the
    /// body turned out to contain. A screen with a Save button should compare
    /// against the loaded row before calling.
    public init() {}
}
