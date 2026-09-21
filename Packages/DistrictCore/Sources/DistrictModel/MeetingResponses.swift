import Foundation

// ⛔ NEITHER MEETINGS ROUTE CARRIES A `success` ENVELOPE, AND THEY DO NOT EVEN
// AGREE WITH EACH OTHER. The list answers a BARE JSON ARRAY
// (`NextResponse.json(results)`, like the call log); the detail answers a BARE
// OBJECT (the raw row, `findFirst` with no `select`). So there is no flag to
// check on either, an empty list is a legitimate "nothing yet", and a DTO that
// expected `{success, …}` fails to decode every response these routes send. See
// `BareArrayEndpoints`, which holds `meetings` and deliberately not
// `meetingDetail`.
//
// ⛔ THERE IS NO RECORDING OF A MEETING TO PLAY, AND A ROOMS SCREEN BUILT ON
// THESE TYPES MUST NOT PROMISE ONE. The `Meeting` model has no recording column
// at all — its artefacts are ``MeetingDetail/summary`` and
// ``MeetingDetail/transcript``, both written by the voice agent's Companion when
// the room closes — and neither meetings route has a recording sibling. The one
// recording surface on this whole API is `calls/{id}/recording`, which is a
// telephone call, answers a **302** to a presigned object, and lives on
// `RedirectEndpoints`. Offering a play control here would be offering a control
// with nothing behind it.

/// One row of `GET /api/district/meetings`.
///
/// ⛔ THIS IS A PROJECTION, NOT THE MEETING ROW, AND THE TWO DIFFER BY MORE THAN
/// OMISSION. The list route RENAMES as it reshapes: `summary` is published as
/// ``summaryPreview`` truncated to 220 characters, and the `participants` JSON
/// array is published as the integer ``participantCount``. Neither original name
/// appears on the wire here, so a client that modelled this from
/// ``MeetingDetail``'s shape would fail to decode every row. That asymmetry runs
/// in one direction only: the detail carries none of this type's two renamed
/// keys either.
///
/// ⛔ ``summaryPreview`` IS NULL FOR EVERY MEETING THAT HAS NOT ENDED, WHICH IS
/// THE ORDINARY CASE RATHER THAN AN EDGE ONE. The Companion writes the minutes
/// when the room closes, so a meeting in progress — including the one the user
/// is sitting in — has no summary, no ``endedAt``, no ``title`` and
/// `durationSec: 0`. `district-meetings.json` carries one row of each shape, so
/// a DTO that regressed either Optional to non-null is caught by the gate rather
/// than on a phone.
///
/// ⚠️ IT IS A PREVIEW AND MUST NOT BE PRESENTED AS THE MINUTES. 220 characters
/// is roughly two sentences; the full text is on the detail route, and a screen
/// that rendered this as complete would be truncating the deliverable without
/// saying so.
///
/// ⚠️ THE TIMESTAMPS ARE ISO-8601 STRINGS, NOT INSTANTS — `NextResponse.json`
/// serialises a Prisma `DateTime` through `JSON.stringify`. This module owns no
/// date parsing, the same call ``CallSummary`` makes.
public struct MeetingSummary: Codable, Sendable {
    public let id: String
    /// ⚠️ The full `meet_<workspaceId>_<suffix>` name, not the human part of it.
    public let roomName: String
    /// ⚠️ Null until somebody names the meeting; nothing generates one.
    public let title: String?
    /// "in-progress" or "completed". Free text on the wire; the column has no
    /// enum, so this is a `String` for the reason ``WorkspaceRole`` documents.
    public let status: String
    /// ⚠️ Nullable in the schema: a row can exist before the room starts.
    public let startedAt: String?
    /// ⚠️ Null for everything still running.
    public let endedAt: String?
    public let createdAt: String
    /// ⚠️ Zero while a meeting is in progress — it is stamped at the end, not
    /// accumulated, so a live meeting reports 0 rather than its elapsed time.
    public let durationSec: Int
    /// ⛔ Truncated to 220 characters, and null until the meeting ends. See the
    /// type doc.
    public let summaryPreview: String?
    /// ⚠️ Zero when the `participants` column is null, which is every meeting
    /// that never ran. The route writes
    /// `Array.isArray(participants) ? length : 0`, so this key is present with a
    /// zero rather than omitted.
    public let participantCount: Int
}

/// `GET /api/district/meetings/[id]` — the WHOLE Prisma row, returned verbatim.
///
/// ⛔ FOUR FIELDS HERE ARE NOT PUBLISHED BY THE LIST AT ALL: ``roomSid``,
/// ``transcript``, ``actionItems`` and ``workspaceId``. That is why this client
/// carries two models rather than treating the list as a subset — and the
/// asymmetry runs both ways, since the list's `summaryPreview` and
/// `participantCount` do not exist here. Both fixtures are committed.
///
/// ⚠️ ``transcript`` IS THE FULL CONVERSATION AND IS THE MOST SENSITIVE FIELD
/// THIS PACKAGE DECODES. It is ordered `Speaker: text` lines written by the
/// Companion, and nothing about it is summarised or redacted, so anywhere it is
/// surfaced is a place a meeting's contents are surfaced.
///
/// ⚠️ A **404** IS ALSO WHAT ANOTHER WORKSPACE'S MEETING ID PRODUCES. The lookup
/// is scoped on both id and workspaceId inside the workspace-context
/// transaction, so "not yours" and "not there" are deliberately
/// indistinguishable, and any message about a 404 has to be worded for both.
///
/// ⛔ NO RECORDING. See the ⛔ at the top of this file before a Rooms screen
/// offers playback.
public struct MeetingDetail: Codable, Sendable {
    public let id: String
    /// LiveKit's own `RM_…` session key.
    ///
    /// ⚠️ NULLABLE BECAUSE THE ROW CAN EXIST BEFORE THE SID DOES — the Companion
    /// creates the record and LiveKit reports the sid separately. It is the
    /// canonical per-session key server-side and means nothing to a person, so
    /// it is not something to display.
    public let roomSid: String?
    public let roomName: String
    public let workspaceId: String
    public let title: String?
    public let status: String
    /// ⛔ The FULL minutes (markdown), not the list's 220-character preview.
    /// Null until the meeting ends.
    public let summary: String?
    /// ⚠️ See the type doc: the complete conversation, unredacted.
    public let transcript: String?
    /// ⚠️ AN UNSTRUCTURED `Json?` COLUMN whose element shape belongs to the voice
    /// agent rather than to this repo — documented as `[{text, owner?}]` and
    /// enforced by nothing. Modelled as opaque ``WireJSON`` for the same reason
    /// `Contact.visualMemory` is: inventing a struct here would make this client
    /// fail to decode the first time the agent adds a key, and a lossy read of a
    /// blob is a silent deletion the day anything writes it back.
    public let actionItems: WireJSON?
    /// ⚠️ Opaque for the same reason as ``actionItems``; documented as
    /// `[{identity, name}]`.
    public let participants: WireJSON?
    /// ⚠️ Stamped at the end, so zero on a meeting still in progress.
    public let durationSec: Int
    public let startedAt: String?
    public let endedAt: String?
    public let createdAt: String
}
