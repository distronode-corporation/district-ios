import Foundation

/// `GET /api/district/timeline?workspaceId=&contactId=` (or `&phoneNumber=`) —
/// one thread's history, with SMS, email and CALLS interleaved.
///
/// ⛔ THIS IS A CONTACT'S WHOLE TIMELINE, NOT A MESSAGE LIST, and the
/// interleaving is the point: an operator reading a thread needs to see that the
/// customer phoned between two texts. A client that filtered to messages only
/// would silently drop the call that explains the gap.
///
/// ⛔ THE DTO ARRIVED LATE ON PURPOSE, AND THE REASON IS WORTH KEEPING. When the
/// repositories landed this was the one MVP read with no `Codable` type, because
/// the route was mid-reshape — it was about to grow ``pageInfo`` — and a DTO
/// pinned against the copy on disk then would have built a gate that failed the
/// day the Android batch landed, presenting a change made on the Android side as
/// an iOS bug in an iOS pipeline. That batch has landed, both fixtures carry the
/// settled shape, and the shape is pinned here.
///
/// ⚠️ THE HAND-WRITTEN READER DID NOT GO AWAY, AND THAT IS NOT BELT-AND-BRACES.
/// `DistrictData.ThreadPageReader` decodes this type FIRST and keeps its
/// shape-guarded ``WireJSON`` walk as a fallback, because a deployed origin can
/// lag the fixture corpus by a release. A document this type refuses still has to
/// render: showing "no messages yet" to a customer who has a history is a worse
/// answer than reading the body defensively.
///
/// ⚠️ PAGED, EXPAND-ONLY, AND ON A CURSOR RATHER THAN AN OFFSET. The server
/// returns the NEWEST window (50 rows per source, messages and calls windowed
/// separately) and ``pageInfo`` says where that window ended. There is no
/// `after`: a thread opens on the newest window and only ever expands backwards.
///
/// ⛔ PAGES MAY OVERLAP, BY CONTRACT, SO A CALLER MUST DEDUPE BY
/// ``TimelineEvent/id``. The two sources are windowed independently and merged
/// afterwards, so one cursor point can sit inside one source's window and past
/// the other's. The server documents this as the deliberate trade against a
/// per-source cursor pair.
public struct TimelineResponse: Codable, Sendable {
    public let success: Bool
    /// ⚠️ OLDEST FIRST. Both server versions sort ascending, which is the reading
    /// order a chat transcript wants and the opposite of every list endpoint in
    /// this API. Do not re-sort.
    public let timeline: [TimelineEvent]
    /// Where this window ended, or nil on a deployment older than the paging
    /// change, which omits the key entirely.
    ///
    /// ⛔ OPTIONAL RATHER THAN REQUIRED, AND THAT IS THE WHOLE COMPATIBILITY
    /// STORY IN ONE FIELD. A required `pageInfo` would turn a lagging origin into
    /// a decode failure — an empty thread on screen — rather than into a thread
    /// with no page behind it, which is exactly what such a server has.
    public let pageInfo: TimelinePageInfo?
}

/// The cursor the next (older) page is fetched with, and whether there is one.
///
/// ⛔ ``hasMore`` MEANS "AT LEAST ONE SOURCE FILLED ITS WINDOW", NOT "THERE ARE
/// DEFINITELY MORE EVENTS". A source with exactly 50 rows left reports true and
/// the following page comes back empty. That is the server's deliberate choice of
/// which way to be wrong (taking 51 rows and discarding one would cost a row on
/// every thread open to save one empty request at the very end), so a client must
/// treat an empty older page as the end of the thread rather than as a fault.
///
/// ⚠️ ``oldest``/``oldestId`` NAME THE OLDEST EVENT OF THE MERGED PAGE, not the
/// oldest row of either source, and they are null only on an empty page. They are
/// echoed back verbatim; parsing or re-formatting the timestamp locally would
/// hand the server a value it never emitted.
public struct TimelinePageInfo: Codable, Sendable {
    public let hasMore: Bool
    /// ISO-8601, straight from the server. Sent back as `before`.
    public let oldest: String?
    /// The id of that same event, breaking ties among rows sharing its timestamp.
    /// Sent back as `beforeId`.
    ///
    /// ⛔ `beforeId` WITHOUT `before` IS A 400, NOT A DEFAULT. An id alone cannot
    /// say which timestamp it breaks a tie at, so the route refuses it rather
    /// than silently serving the newest window forever while the client believes
    /// it is walking backwards. The two travel together, which is why
    /// `DistrictData.ThreadCursor` cannot hold one without the other.
    public let oldestId: String?
}

/// One event in a contact's history.
///
/// ⚠️ RAW STRINGS FOR ``type`` AND ``direction``, LIKE EVERY DTO IN THIS MODULE.
/// Neither column is a database enum, and decoding into a Swift enum would fail
/// closed on a value the server adds later — taking out the whole thread rather
/// than one label.
///
/// ⚠️ ``direction`` INCLUDES `missed`, which is neither inbound nor outbound. A
/// two-state boolean would have to put a missed call on one side of the
/// conversation or the other, and both are wrong: a missed call is an event, not
/// a message from anybody.
///
/// ⛔ AND ON A CALL ROW ``direction`` IS AN OUTCOME RATHER THAN A DIRECTION. The
/// server's timeline mapper ignores `Call.direction` entirely and labels every
/// non-failed call `inbound`, reserving `missed` for failed/no-answer — so an
/// OUTBOUND call appears here as `inbound`. Do not build a "you called them"
/// caption from it; `CallSummary.direction` on the calls feed is the field that
/// means what it says.
///
/// ⚠️ THE OPTIONALS ARE THE FIELDS THE FIXTURES OMIT, NOT THE FIELDS THAT CAN BE
/// NULL. Neither timeline fixture carries a single explicit null: `duration`,
/// `summary` and `hasTranscript` are simply absent on a message row, `subject` on
/// anything that is not an email, and `mediaUrls` on a message with no
/// attachments. The strict gate compares key sets, so each of these has to be an
/// Optional for the re-encode to omit the key exactly where the fixture does.
public struct TimelineEvent: Codable, Sendable {
    /// The `Message.id` or `Call.id` this row came from.
    ///
    /// ⚠️ UNIQUE ACROSS BOTH SOURCES ONLY BECAUSE cuids ARE. The server merges two
    /// queries without namespacing their ids.
    public let id: String
    /// `sms`, `email`, `whatsapp` or `call`.
    public let type: String
    /// ISO-8601 from the server.
    ///
    /// ⛔ A MACHINE INSTANT, AND THE UI MUST FORMAT IT. The server writes
    /// `createdAt.toISOString()` on both the message and the call branch and applies
    /// no timezone formatting at all, so rendering it verbatim prints
    /// `2026-08-15T14:20:00.000Z` under every bubble.
    ///
    /// ⚠️ THIS MODULE STILL OWNS NO DATE PARSING. The value is carried as the server's own string — it is also what a
    /// cursor is echoed back as, where re-formatting it would hand the server a
    /// timestamp it never emitted. The formatting belongs at the point of DISPLAY.
    public let timestamp: String
    /// `inbound`, `outbound` or `missed`. See the ⛔ on the type.
    public let direction: String
    /// ⚠️ NEVER NULL, BUT LEGITIMATELY EMPTY. The server writes `msg.body || ""`,
    /// and a call row carries its summary here (or the literal "AI call
    /// completed." when it has none).
    public let body: String
    public let status: String
    /// Email rows only. ⚠️ ABSENT, not null, on every other kind.
    public let subject: String?
    /// MMS and email attachments. ⚠️ The key is OMITTED when there are none, so
    /// nil here means "none" rather than "the server did not say".
    ///
    /// ⛔ THESE ARE ANONYMOUS CAPABILITY URLs (`/api/media/<uuid>`) and must be
    /// loaded WITHOUT this client's bearer token.
    public let mediaUrls: [String]?
    /// Call rows only, in seconds.
    public let duration: Int?
    /// The voice agent's post-call summary, when one exists.
    public let summary: String?
    /// Whether a call row has a stored transcript.
    ///
    /// ⛔ THE TRANSCRIPT ITSELF IS NOT IN THIS PAYLOAD, DELIBERATELY, AND THAT IS
    /// WHY THERE IS NO `transcript` FIELD HERE EVEN THOUGH THE KOTLIN TYPE STILL
    /// CARRIES ONE. Transcripts would dominate the response on every thread open;
    /// the flag exists so the UI can offer the control and
    /// fetch the text from `calls/{id}/transcript` only when it is tapped. Adding
    /// the field back would model a key neither fixture has.
    public let hasTranscript: Bool?
}
