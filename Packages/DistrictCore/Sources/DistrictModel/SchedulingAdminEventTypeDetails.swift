import Foundation

// The four rows that hang off an event type: its hosts, its booking questions,
// the slots it offers, and the acknowledgement of a test email.
//
// ⛔ SPLIT FROM `SchedulingAdminEventTypes.swift` FOR THE 500-LINE `file_length`
// CEILING, which `swiftlint --strict` promotes to an error — the same reason
// `AllowedExplicitNulls+Union.swift` and `ImplementedFixtures+SchedulingAdmin.swift`
// exist. It is not a boundary in the domain: everything here is addressed by the
// event type's `slug`.

/// One member assigned to an event type, as the scheduler serves them.
///
/// ⛔ `user_id` IS THE SCHEDULER'S USER ID AND NOT A DISTRICT MEMBER ID. The two
/// namespaces are joined inside the fork, which is why nothing on this row can be
/// looked up against a District workspace directory — and why
/// ``SchedulingHostAssignment`` takes the same opaque string back rather than
/// offering a member picker keyed on District ids.
///
/// ⚠️ `avatar_url` IS ABSENT, NEVER NULL. The handler omits the key for a member
/// who has not uploaded one, so this Optional round-trips as a missing key and
/// needs no entry in the explicit-null register.
///
/// ⚠️ `archived` IS PRESENT ON A HOST THAT IS STILL ASSIGNED, which reads as a
/// contradiction and is not one: archiving a scheduler user leaves their host rows
/// in place so historical bookings keep an owner. A host list is therefore not a
/// list of people who can be booked.
public struct SchedulingHost: Codable, Equatable, Sendable {
    public let userId: String
    public let name: String
    public let email: String
    public let avatarUrl: String?
    /// `required`, `rotation` or `optional` — the three values
    /// `eventTypes.hosts.put` accepts.
    public let role: String
    /// ⚠️ MEANINGFUL ONLY UNDER ONE OF THE THREE `rr_strategy` VALUES the catalog
    /// permits (`even`, `soonest`, `priority`), and the row does not say which one
    /// the event type is on — read it beside ``SchedulingEventType/rrStrategy``
    /// rather than as a ranking that always applies.
    public let priority: Int
    public let archived: Bool

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case name
        case email
        case avatarUrl = "avatar_url"
        case role
        case priority
        case archived
    }
}

/// One question asked on the booking form.
///
/// ⛔ `options` IS NULL FOR EVERY NON-`select` QUESTION AND THAT IS THE WIRE
/// SHAPE, not an omission: the column is a nullable array the fork marshals
/// without `omitempty`. A `text` question carrying `[]` and one carrying `null`
/// would mean the same thing to a reader and do not arrive the same way, so the
/// null is registered in `AllowedExplicitNulls+SchedulingA.swift` rather than
/// defaulted away.
///
/// ⚠️ `event_type_id` IS PRESENT AND NON-NULL HERE, unlike on
/// ``SchedulingAvailabilityRule`` where the same key is nullable and its null
/// means "every event type". The names rhyme and the meanings do not.
public struct SchedulingQuestion: Codable, Equatable, Sendable {
    public let id: String
    public let eventTypeId: String
    public let label: String
    /// `text`, `select` or `checkbox`.
    public let type: String
    /// ⚠️ NULLABLE. See the type doc.
    public let options: [String]?
    public let required: Bool
    public let position: Int

    enum CodingKeys: String, CodingKey {
        case id
        case eventTypeId = "event_type_id"
        case label
        case type
        case options
        case required
        case position
    }
}

/// One bookable window.
///
/// ⚠️ `start` AND `end` ARE INSTANTS, NOT THE `HH:MM` WALL CLOCK the availability
/// rules and overrides use. Three types in this family carry a `start`/`end` pair
/// and all three mean something different — instants here, wall-clock times on
/// ``SchedulingAvailabilityRule``, and DATES on ``SchedulingOverrideGroup``.
///
/// ⛔ `host_ids` IS NULL ON A `fixed` EVENT TYPE, where there is one host and the
/// slot does not name them. A caller that read the null as "nobody is available"
/// would hide every slot on the most common routing mode there is.
public struct SchedulingSlot: Codable, Equatable, Sendable {
    public let start: String
    public let end: String
    /// ⚠️ NULLABLE. See the type doc.
    public let hostIds: [String]?

    enum CodingKeys: String, CodingKey {
        case start
        case end
        case hostIds = "host_ids"
    }
}

/// The display half of a host, keyed by scheduler user id in
/// ``SchedulingSlots/hosts``.
///
/// ⚠️ `avatar_url` IS REQUIRED HERE AND OPTIONAL ON ``SchedulingHost``, which is
/// what the catalog's two schemas say and is the whole reason this is a separate
/// type rather than a reuse. One column, two wire shapes, arriving from two
/// handlers; a shared type would have to take the looser of the two and would
/// stop the gate noticing the day either changes.
public struct SchedulingSlotHost: Codable, Equatable, Sendable {
    public let name: String
    public let avatarUrl: String

    enum CodingKeys: String, CodingKey {
        case name
        case avatarUrl = "avatar_url"
    }
}

/// What `eventTypes.slots` answers.
///
/// ⛔ `taken` IS ABSENT UNLESS THE EVENT TYPE OPTED INTO `show_taken_slots`, and
/// an absent `taken` is NOT an empty diary. The two readings differ on screen by
/// everything: "this host has nothing booked" versus "this host does not publish
/// what is booked". ⚠️ It is `nullish` in the catalog, so it can also arrive as an
/// explicit null; both spellings decode to nil here and the distinction is not
/// recoverable, which is acceptable because the fork sends one or the other for
/// the same reason.
///
/// ⚠️ `hosts` IS ABSENT ON A `fixed` EVENT TYPE for the same reason
/// ``SchedulingSlot/hostIds`` is null there.
public struct SchedulingSlots: Codable, Equatable, Sendable {
    public let slots: [SchedulingSlot]
    public let hosts: [String: SchedulingSlotHost]?
    /// ⚠️ ABSENT, not empty, unless the event type publishes taken slots.
    public let taken: [SchedulingSlot]?
}

/// The acknowledgement `eventTypes.testEmail` answers.
///
/// ⛔ `sent: true` IS THE SCHEDULER HAVING HANDED THE MESSAGE TO ITS MAIL
/// TRANSPORT, not the message having arrived. The op spends a write from the
/// workspace's budget and its honest report is "accepted for delivery"; a screen
/// that says "sent to you" is overstating an outcome nothing here observed.
///
/// ⚠️ `to` IS THE CALLING MEMBER'S OWN SCHEDULER ADDRESS, chosen by the fork and
/// not by the caller — there is no recipient parameter, deliberately, because one
/// would make this op a mail relay addressable by anybody holding a viewer's key.
public struct SchedulingTestEmailResult: Codable, Equatable, Sendable {
    public let sent: Bool
    public let to: String
}
