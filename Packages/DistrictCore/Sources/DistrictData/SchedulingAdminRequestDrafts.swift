import Foundation

// The four smaller request shapes of the event-type and availability ops.
//
// ⛔ SPLIT FROM `SchedulingAdminEventTypeDrafts.swift` FOR THE 500-LINE
// `file_length` CEILING that `swiftlint --strict` promotes to an error, not for a
// boundary in the domain. Everything in both files is a request body the catalog
// validates and this side does not — see the ⛔ there.

/// One host assignment, as `eventTypes.hosts.put` takes it.
///
/// ⛔ THE PUT IS A FULL REPLACEMENT AND NOT A DELTA, WHICH IS THE ONE THING A
/// CALLER MUST KNOW ABOUT THIS TYPE: sending an array of one REMOVES every other
/// host from the event type. The schema also requires the array to be non-empty,
/// so "remove the last host" is not expressible — the op cannot leave an event
/// type hostless, and a UI that offers a delete on the final row is offering a 400.
///
/// ⚠️ `userId` IS THE SCHEDULER'S USER ID, taken back from
/// ``SchedulingHost/userId``. It does not resolve against a District workspace
/// directory; the join lives inside the fork.
public struct SchedulingHostAssignment: Sendable, Equatable {
    public var userId: String
    /// `required`, `rotation` or `optional`.
    public var role: String
    public var priority: Int

    public init(userId: String, role: String, priority: Int) {
        self.userId = userId
        self.role = role
        self.priority = priority
    }
}

/// A new booking question, as `eventTypes.questions.create` takes it.
///
/// ⚠️ `position` IS OPTIONAL ON CREATE AND REQUIRED-LOOKING ON THE ROW. The read
/// side always carries one; omitting it here lets the fork append, which is what a
/// form's "Add question" means and is why this is not defaulted to 0 — a literal 0
/// would insert at the top.
///
/// ⛔ `options` IS MEANINGFUL ONLY FOR A `select`, and the catalog does not refuse
/// it on a `text`. So a question that was a select and became a text keeps its
/// options server-side unless they are overwritten, and a form that hid the control
/// on type change would leave them there silently.
public struct SchedulingQuestionDraft: Sendable, Equatable {
    public var label: String
    /// `text`, `select` or `checkbox`.
    public var type: String
    public var required: Bool
    /// At most fifty, each at most 200 characters. See the ⛔ on the type.
    public var options: [String]?
    public var position: Int?

    /// ⚠️ THE THREE THE SCHEMA REQUIRES. `required` is one of them and has no
    /// default here deliberately: a question's optionality is a decision on every
    /// form, and a defaulted `false` would make the commonest mistake the quiet one.
    public init(label: String, type: String, required: Bool) {
        self.label = label
        self.type = type
        self.required = required
    }
}

/// The fields `eventTypes.questions.patch` may change.
///
/// ⛔ nil IS "LEAVE ALONE". Same rule as ``SchedulingEventTypeChanges``, same
/// consequence: there is no way through this type to clear `options` back to null.
public struct SchedulingQuestionChanges: Sendable, Equatable {
    public var label: String?
    /// `text`, `select` or `checkbox`.
    public var type: String?
    public var options: [String]?
    public var required: Bool?
    public var position: Int?

    public init() {}
}

/// A dated exception to the weekly rules, as `availability.overrides.create` takes
/// it.
///
/// ⛔ `endDate` IS WHAT DECIDES WHICH OF TWO SHAPES COMES BACK. With it, the op
/// answers a ``SchedulingOverrideGroup`` summary and no row at all; without it, a
/// single ``SchedulingAvailabilityOverride``. That is the union
/// ``SchedulingOverrideCreated`` exists for, and it is a property of THIS field
/// rather than of the response — which is why the two are documented together.
///
/// ⚠️ `reason` IS A CLOSED SET (`day_off`, `out_of_office`, `custom_hours`) AND NOT
/// FREE TEXT, even though ``SchedulingAvailabilityOverride/reason`` is a plain
/// `String` on the way back. It reads like a note field and is not one.
///
/// ⛔ `startTime` AND `endTime` ARE ZERO-PADDED `HH:MM` AND ONLY MEAN ANYTHING
/// UNDER `custom_hours`. An all-day block sends neither, and the row it creates
/// carries an explicit null for both.
public struct SchedulingOverrideDraft: Sendable, Equatable {
    /// `YYYY-MM-DD`.
    public var date: String
    /// `day_off`, `out_of_office` or `custom_hours`.
    public var reason: String
    /// `YYYY-MM-DD`. ⛔ Present means a RANGE, and a range answers a summary. See
    /// the type doc.
    public var endDate: String?
    /// Zero-padded `HH:MM`.
    public var startTime: String?
    /// Zero-padded `HH:MM`.
    public var endTime: String?

    public init(date: String, reason: String) {
        self.date = date
        self.reason = reason
    }
}
