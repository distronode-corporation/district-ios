import Foundation

// The row DTOs for the scheduling admin's `calendar.*` namespace, plus
// `zoom.status`.
//
// ⚠️ THIS WHOLE NAMESPACE IS `viewer`, INCLUDING ITS WRITES, and that is not an
// oversight in the catalog's role table: these are the CALLER'S OWN calendar
// connections, so a viewer connecting their own Google account is not a tenancy
// change. See `SchedulingAdminOp+Access.swift`.
//
// ⚠️ SNAKE_CASE ON THE WIRE — the scheduler fork's convention, spelled out in
// `CodingKeys` rather than converted. Same note as `SchedulingAdminBookings.swift`.

/// One calendar account the caller has connected.
///
/// ⛔ `id` IS NOT A STABLE IDENTITY AND MUST NOT BE STORED AS ONE. The fork
/// recreates a connection id on every token refresh; identity is carried by
/// `provider` + `account_email`, which is why every op that addresses a
/// connection REQUIRES `provider` in the params and treats the `{id}` in the path
/// as decorative. A screen that cached the id and came back after a refresh would
/// address a connection that no longer answers to it.
///
/// ⚠️ `is_destination` AND `check_conflicts` ARE DIFFERENT QUESTIONS. The first
/// is where new bookings get WRITTEN (exactly one connection holds it); the
/// second is which calendars are READ for busy time, and any number may.
public struct SchedulingCalendarConnection: Codable, Sendable {
    public let id: String
    public let provider: String
    public let accountEmail: String
    public let isDestination: Bool
    public let checkConflicts: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case provider
        case accountEmail = "account_email"
        case isDestination = "is_destination"
        case checkConflicts = "check_conflicts"
    }
}

/// What `calendar.status` answers: what the instance offers, and what the caller
/// has actually connected.
///
/// ⛔ `providers` AND `unconfiguredProviders` ARE `.nullish()` ON THE SERVER, NOT
/// `.optional()`, AND THE DIFFERENCE CAN BREAK A WHOLE PAGE. Both
/// are Go slices the fork marshals WITHOUT `omitempty`, so a nil slice crosses
/// the wire as an explicit `null` rather than as an absent key.
/// `unconfigured_providers` is nil exactly when Google AND Microsoft are both
/// configured — i.e. on every production tenant — and typing it `.optional()`
/// makes the whole calendar page read "could not be read" for every customer. The
/// Optional here therefore covers BOTH absence and null, which is
/// what a Swift Optional already does; the note exists so nobody narrows it.
///
/// ⚠️ THE CONTRACT FIXTURE CARRIES REAL ARRAYS FOR BOTH, so neither has an
/// `allowedExplicitNulls` entry and neither should get one — an entry is
/// permission for a null the bytes demonstrate, and permission for one they do
/// not would keep being granted the day the server stops sending it. The null
/// branch is decoded from inline bytes in `SchedulingAdminCalendarTests` instead,
/// which is the same call `AllowedExplicitNulls+Inbox.swift` makes for
/// `message.type`.
///
/// ⚠️ `connected` AND `configured` ARE NOT THE SAME QUESTION EITHER. `configured`
/// is whether the INSTANCE has calendar credentials at all (an operator concern);
/// `connected` is whether THIS caller has linked an account. A tenant can be
/// configured and unconnected, which is the ordinary state of a new member.
public struct SchedulingCalendarStatus: Codable, Sendable {
    public let connected: Bool
    public let configured: Bool
    /// Every provider the instance can offer. ⚠️ Null, not `[]`, when the fork
    /// has none to report.
    public let providers: [String]?
    public let connections: [SchedulingCalendarConnection]
    /// The subset of ``providers`` the instance has NOT been given credentials
    /// for. ⚠️ Null on a fully configured instance — the common case.
    public let unconfiguredProviders: [String]?
    /// The provider of the destination connection, when there is one.
    public let provider: String?

    enum CodingKeys: String, CodingKey {
        case connected
        case configured
        case providers
        case connections
        case unconfiguredProviders = "unconfigured_providers"
        case provider
    }
}

/// What `calendar.caldav.connect` answers.
///
/// ⚠️ A CONFIRMATION, NOT A CONNECTION ROW. It carries neither an id nor the
/// provider, so it cannot be appended to
/// ``SchedulingCalendarStatus/connections`` — re-read the status after a
/// successful connect rather than synthesising a row from these two fields.
///
/// ⛔ `accountEmail` IS WHAT THE SERVER RESOLVED, NOT WHAT WAS SENT. CalDAV
/// usernames are frequently not email addresses, and the fork answers the address
/// it discovered on the principal; echoing back the submitted `username` would
/// label the connection with something the provider does not recognise.
public struct SchedulingCaldavConnection: Codable, Sendable {
    public let connected: Bool
    public let accountEmail: String

    enum CodingKeys: String, CodingKey {
        case connected
        case accountEmail = "account_email"
    }
}

/// One calendar inside a connected account, and how it is being used.
///
/// ⛔ ONLY `id` AND `name` ARE GUARANTEED. Row 1 of
/// `district-scheduling-calendars.json` is a read-only holiday calendar carrying
/// exactly those two — the four flags are ABSENT rather than false — so a client
/// that typed any of them non-optional would throw on a subscription calendar,
/// which almost every Google account has. ⚠️ Absent is not the same as false to a
/// reader even though it renders the same: absent means the fork did not say.
///
/// ⚠️ THIS IS ALSO THE REQUEST SHAPE. `calendar.connections.calendars.put` takes
/// an array of exactly these objects, which is why the type carries a public
/// memberwise initialiser — the PUT is "send back the GET's rows with the flags
/// you changed", and building it from anything else risks dropping a calendar the
/// user never touched.
public struct SchedulingCalendarSelection: Codable, Sendable {
    public let id: String
    public let name: String
    public let primary: Bool?
    public let writable: Bool?
    public let checkConflicts: Bool?
    public let isDestination: Bool?

    public init(
        id: String,
        name: String,
        primary: Bool? = nil,
        writable: Bool? = nil,
        checkConflicts: Bool? = nil,
        isDestination: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.primary = primary
        self.writable = writable
        self.checkConflicts = checkConflicts
        self.isDestination = isDestination
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case primary
        case writable
        case checkConflicts = "check_conflicts"
        case isDestination = "is_destination"
    }
}

/// The container `calendar.connections.calendars.get` answers.
///
/// ⛔ `{calendars:[…]}`, NOT `{items:[…]}`, AND THE DIFFERENCE IS WHY THIS TYPE
/// EXISTS RATHER THAN A ``SchedulingItems`` SPECIALISATION. Three envelope
/// conventions live on this API and the key is part of the contract: the strict
/// gate compares KEY SETS, so `items` here would be reported as one dropped key
/// and one added one.
public struct SchedulingCalendarSelections: Codable, Sendable {
    public let calendars: [SchedulingCalendarSelection]
}

/// What `zoom.status` answers.
///
/// ⛔ READ ONLY, AND THE ONLY ZOOM OP IN THE CATALOG. `GET|PATCH
/// /v1/settings/zoom` hold the INSTANCE's Zoom credentials — shared by every
/// tenancy on the deployment — and are excluded from the allowlist for the same
/// reason the other `/v1/settings/*` routes are. Nothing on this client can
/// change Zoom's configuration, by construction.
///
/// ⚠️ `configured` IS THE INSTANCE'S, `connected` IS THE CALLER'S, and the
/// fixture is the `true`/`false` pair on purpose: an instance with Zoom
/// credentials whose member has not linked an account is the ordinary state, and
/// it is the one combination a screen has to give an action for.
public struct SchedulingZoomStatus: Codable, Sendable {
    public let configured: Bool
    public let connected: Bool
}
