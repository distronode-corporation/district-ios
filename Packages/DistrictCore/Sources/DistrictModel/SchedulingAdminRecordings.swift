import Foundation

// The `recordings.*` rows: the list, the bulk-delete tally, and the consent roll.
//
// ⚠️ SNAKE_CASE ON THE WIRE and `Codable` rather than `Decodable`, for the
// reasons `SchedulingAdminSettings.swift` states at length. Both files are the
// scheduler fork's vocabulary passing through our RPC.

/// One recorded meeting.
///
/// ⛔ ONLY `id` AND `status` ARE GUARANTEED, AND A ROW CAN LEGITIMATELY BE JUST
/// THOSE TWO. `district-scheduling-recordings.json` carries exactly that shape in
/// row 1: a recording whose capture FAILED has no room, no duration, no file and
/// no booker, because none of them was ever written. A DTO that required
/// `booking_id` would throw on the one row an operator most needs to see, and the
/// failure would present as "recordings are broken" rather than "one recording
/// failed".
///
/// ⚠️ THE MISSING KEYS ARE ABSENT, NOT NULL. `JSON.stringify` drops an undefined,
/// and the catalog types every one of them `.optional()` rather than
/// `.nullable()`, so these Optionals mean "no key arrived" and none of them has
/// an entry in the explicit-null register. Checked against the fixture bytes.
public struct SchedulingRecording: Codable, Equatable, Sendable {
    public let id: String
    /// ⚠️ Absent on a recording that never bound to a booking.
    public let bookingId: String?
    /// The LiveKit room it was captured in (`booking-<bookingId>`). ⚠️ A label,
    /// not a handle: the room is long gone by the time this row is read, and
    /// ``SchedulingAdminOp/recordingsList`` is not a way to rejoin anything.
    public let room: String?
    /// `ready`, `failed`, and whatever the fork adds next. ⚠️ A `String`, not an
    /// enum: this is a status column with no server-side union, so an unknown
    /// value is a label to show rather than a response to reject.
    public let status: String
    /// Seconds. ⚠️ Absent on a failed capture, which is a different fact from `0`.
    public let durationS: Int?
    /// Whether an object actually exists to download. ⛔ A FILE IS NOT IMPLIED BY
    /// `status == "ready"` AND THIS IS THE FIELD THAT SAYS SO. A row whose object
    /// was reaped by retention keeps its status and loses its file, and the
    /// download route answers 404 for it — so a Play button drawn off `status`
    /// fails in the player rather than being absent from the row.
    public let hasFile: Bool?
    public let createdAt: String?
    /// Who booked the meeting. ⚠️ PERSONAL DATA on a list screen: it is the
    /// customer's customer, not their staff.
    public let bookerName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case bookingId = "booking_id"
        case room
        case status
        case durationS = "duration_s"
        case hasFile = "has_file"
        case createdAt = "created_at"
        case bookerName = "booker_name"
    }
}

/// `recordings.list`, which answers `{recordings: […]}` and NOT `{items: […]}`.
///
/// ⛔ THE CONTAINER KEY IS NOT `items`, AND THIS IS THE ONE LIST ON THE SURFACE
/// WHERE THAT IS TRUE. Every developer-tab list uses the catalog's `items(...)`
/// helper; `recordings.list` declares `z.object({ recordings: ... })` by hand and
/// the fork answers in kind. Decoding it through ``SchedulingItems`` throws a
/// missing-key error that reads like an outage, so the container is spelled out
/// here rather than reused.
///
/// ⚠️ NEWEST FIRST, LIMIT 200, NO PAGING, AND NO QUERY PARAMETERS EXIST TO CHANGE
/// ANY OF IT. A workspace past 200 recordings cannot reach the older ones from
/// this op at all, which is a product limit to state on the screen rather than
/// something a client can page around.
public struct SchedulingRecordingList: Codable, Equatable, Sendable {
    public let recordings: [SchedulingRecording]
}

/// What `recordings.deleteAll` came to.
///
/// ⛔ A PARTIAL FAILURE IS A **200**, AND ``failed`` IS THE ONLY PLACE IT IS
/// REPORTED. The op deletes per object and tallies; nothing about the HTTP status
/// changes when some of them do not go. A screen that rendered "all deleted" off
/// a successful call would tell a customer their recordings are gone while
/// ``failed`` of them are still in the bucket — which, on a surface whose whole
/// purpose is data removal, is the worst available wrong answer.
public struct SchedulingRecordingsDeleted: Codable, Equatable, Sendable {
    public let deleted: Int
    /// ⛔ Non-zero means SOME ARE STILL THERE. See the type note.
    public let failed: Int
}

/// One participant's recording consent.
///
/// ⛔ THE EVIDENCE FOR A TWO-PARTY-CONSENT JURISDICTION, WHICH IS WHY IT IS ITS
/// OWN OP RATHER THAN A FIELD ON THE RECORDING. A row here is what the platform
/// can show if asked whether a person agreed to be recorded, so a client must
/// render what it says and never fill a gap: `pending` is a real, common state
/// (the guest left before the prompt resolved) and is NOT "granted by default".
public struct SchedulingRecordingConsent: Codable, Equatable, Sendable {
    /// The LiveKit participant identity (`host-<userId>`, `guest-<name>`).
    /// ⚠️ Not an email and not a District user id: it is what the room knew.
    public let identity: String
    /// ⚠️ Absent for a participant who never gave one — row 1 of the fixture.
    /// A screen falls back to ``identity``, which always exists.
    public let name: String?
    /// `granted`, `pending`, and whatever the fork adds. A `String` for
    /// ``SchedulingRecording/status``'s reason. ⛔ Do not default an unknown value
    /// to `granted`.
    public let decision: String
    /// ⚠️ Absent while ``decision`` is `pending`, which is the pair that makes the
    /// row readable: a decision with no timestamp has not been made.
    public let decidedAt: String?

    enum CodingKeys: String, CodingKey {
        case identity
        case name
        case decision
        case decidedAt = "decided_at"
    }
}

/// `recordings.consent`, which answers `{consents: […]}`.
///
/// ⚠️ ANOTHER BESPOKE CONTAINER KEY. See ``SchedulingRecordingList``.
public struct SchedulingRecordingConsents: Codable, Equatable, Sendable {
    public let consents: [SchedulingRecordingConsent]
}
