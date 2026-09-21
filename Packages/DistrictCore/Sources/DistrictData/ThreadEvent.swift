import DistrictModel
import DistrictNetwork
import Foundation

/// One entry in a customer's thread: an SMS, an email, a WhatsApp message or a
/// call, all interleaved.
///
/// ⛔ THE WIRE SHAPE IS PINNED BY ``TimelineResponse`` NOW, AND THIS TYPE IS THE
/// APP-FACING PROJECTION OF IT RATHER THAN THE ONLY READER OF THE ROUTE. Until
/// the Android parity batch landed, `district-timeline.json` was skip-listed in
/// `ContractManifest` and there was no DTO at all: the route was growing a
/// `pageInfo` block, and a DTO pinned against the copy on disk then would have
/// red the iOS contract gate the day that batch landed, presenting a change made
/// on the Android side as an iOS bug. Both fixtures now carry the settled shape,
/// both are gated, and ``ThreadPageReader`` decodes `TimelineResponse` FIRST.
///
/// ⚠️ THE HAND-WRITTEN ``JSONValue`` WALK IS STILL HERE AS THE FALLBACK, AND IT
/// IS NOT REDUNDANCY. A deployed origin can lag the fixture corpus by a release,
/// so the reader stays **compatible with both shapes**:
///
///   - pre-paging: `{success, timeline: [...]}`, no cursor, no paging;
///   - settled: `{success, timeline: [...], pageInfo: {hasMore, oldest,
///     oldestId}}`.
///
/// Both of those decode typed today; what the fallback exists for is a document
/// the DTO refuses — a row missing a field the DTO requires, an `Int` where a
/// `String` is expected — because rendering such a thread defensively is a better
/// answer than showing "no messages yet" to a customer who has a history.
///
/// ⚠️ THE FALLBACK IS NOT LOOSER THAN THE DTO IN WHAT IT PRODUCES, ONLY IN WHAT
/// IT ACCEPTS. Every field is read through a shape-guarded accessor, an
/// unreadable row is counted rather than waved through (see
/// ``ThreadPage/droppedEventCount``), and both paths are asserted to produce the
/// same ``ThreadEvent`` values for any document that decodes typed.
///
/// ⚠️ RAW STRINGS FOR ``type`` AND ``direction``, LIKE EVERY DTO IN
/// `DistrictModel`. Neither column is a database enum, and decoding into a Swift
/// enum would fail closed on a value the server adds later — taking out the whole
/// thread rather than one label.
public struct ThreadEvent: Sendable, Equatable, Identifiable {
    /// The `Message.id` or `Call.id` this entry came from.
    ///
    /// ⚠️ UNIQUE ACROSS BOTH SOURCES ONLY BECAUSE cuids ARE. The server merges two
    /// queries without namespacing their ids, so this is the list key on the
    /// server's word rather than by construction.
    public let id: String
    /// `sms`, `email`, `whatsapp` or `call`.
    public let type: String
    /// `inbound`, `outbound` or `missed`.
    ///
    /// ⚠️ A CALL ROW USES THIS FIELD FOR SOMETHING ELSE, AND THE SERVER SAYS SO
    /// IN ITS OWN COMMENT: the timeline mapper ignores `Call.direction` entirely
    /// and labels every non-failed call `inbound`, reserving `missed` for
    /// `failed`/`no-answer`. So on a call row this reads as an OUTCOME, not a
    /// direction, and an outbound call appears here as `inbound`. Do not build a
    /// "you called them" caption from it; ``CallSummary/direction`` on the calls
    /// feed is the field that means what it says.
    public let direction: String
    /// ISO-8601 instant. The only sortable value on the row.
    public let timestamp: String
    /// ⚠️ NEVER NULL, BUT LEGITIMATELY EMPTY. The server writes `msg.body || ""`,
    /// and a call row carries its summary here (or the literal
    /// "AI call completed." when it has none).
    public let body: String
    public let status: String
    /// Email rows only. Absent — not null — on every other kind.
    public let subject: String?
    /// MMS attachments. ⚠️ The key is OMITTED when there are none, so an empty
    /// array here means "none", never "the server did not say".
    ///
    /// ⛔ THESE ARE ANONYMOUS CAPABILITY URLs (`/api/media/<uuid>`) and must be
    /// loaded WITHOUT this client's bearer token — see ``UploadedMedia/url``.
    public let mediaUrls: [String]
    /// Call rows only, in seconds.
    public let durationSeconds: Int?
    /// Call rows only.
    public let summary: String?
    /// Whether a call row has a stored transcript.
    ///
    /// ⛔ THE TRANSCRIPT ITSELF IS NOT IN THIS PAYLOAD, DELIBERATELY. It used to
    /// be, and transcripts dominated the response on every thread open; the flag
    /// exists so the UI can offer the control and fetch the text from
    /// `calls/{id}/transcript` only when it is actually tapped.
    public let hasTranscript: Bool

    /// True for a call row, which renders differently from a message.
    public var isCall: Bool {
        type == ThreadEventKind.call
    }

    /// True when the workspace sent this, rather than the customer.
    ///
    /// ⚠️ FALSE FOR A CALL ROW WHATEVER THE CALL'S REAL DIRECTION — see the ⚠️ on
    /// ``direction``.
    public var isOutbound: Bool {
        direction == ThreadEventDirection.outbound
    }
}

/// The `type` vocabulary the timeline mapper writes.
public enum ThreadEventKind {
    public static let sms = "sms"
    public static let email = "email"
    public static let whatsapp = "whatsapp"
    public static let call = "call"
}

/// The `direction` vocabulary. ⚠️ `missed` is call-only.
public enum ThreadEventDirection {
    public static let inbound = "inbound"
    public static let outbound = "outbound"
    public static let missed = "missed"
}

/// One window of a thread, and whether there is an older one to ask for.
public struct ThreadPage: Sendable, Equatable {
    /// ⚠️ OLDEST FIRST. Both server versions sort ascending, which is the reading
    /// order a chat transcript wants and the opposite of every list endpoint in
    /// this API. Do not re-sort.
    public let events: [ThreadEvent]

    /// What to send back to read the window before this one, or nil when the
    /// server did not offer one.
    public let cursor: ThreadCursor?

    /// ⛔ FALSE WHEN THE SERVER SENT NO `pageInfo`, AND THAT IS CORRECT RATHER
    /// THAN PESSIMISTIC. The deployed route has no paging at all: it returns a
    /// fixed 50-per-source window and ignores `before`/`beforeId` entirely. A
    /// client that offered "load older" anyway would send a cursor the server
    /// discards, receive **the same window again**, and either append every row
    /// twice or spin forever on a button that never runs out. Offering nothing is
    /// the honest answer until the route grows the block that makes the offer
    /// meaningful.
    public let hasMore: Bool

    /// How many rows in the response could not be read.
    ///
    /// ⛔ COUNTED, NOT SWALLOWED, AND NOT FATAL EITHER. Dropping the whole thread
    /// over one unreadable row is the mistake `CallSummary.from` documents in the
    /// other direction — a customer with a hundred messages should not lose all of
    /// them to one. But a silent drop is a thread that is quietly missing
    /// somebody's reply, so the count travels with the page and the UI says the
    /// history is incomplete. Non-zero here is contract drift worth a bug report,
    /// not a user error.
    public let droppedEventCount: Int

    /// True when this window is not the whole story for a reason worth captioning.
    public var isIncomplete: Bool {
        droppedEventCount > 0
    }
}

/// Reads a timeline response: typed first, shape-guarded second.
///
/// ⚠️ `enum` WITH STATIC MEMBERS RATHER THAN FREE FUNCTIONS, matching
/// ``ResponseEnvelope``: it keeps the mapping addressable from a test without
/// widening the module's namespace.
enum ThreadPageReader {
    /// - Parameter document: the enveloped response, AFTER
    ///   ``ResponseEnvelope/require(_:_:)`` has affirmed `success`.
    ///
    /// ⛔ TYPED FIRST, AND THE FALLBACK ONLY FOR A DOCUMENT THE DTO REFUSES. The
    /// two paths are not alternatives of equal standing: ``TimelineResponse`` is
    /// what the contract gate pins, so it is what the client must be reading on
    /// every response the fixtures describe. The ``JSONValue`` walk below runs
    /// only when the typed decode throws, which on a healthy fleet is never.
    ///
    /// ⚠️ THE RE-ENCODE IS THE PRICE OF THE SEAM, NOT AN OVERSIGHT. This function
    /// receives a decoded ``JSONValue`` because ``ResponseEnvelope/require(_:_:)``
    /// has already affirmed `success` on it, so reaching the DTO means going back
    /// to bytes. Changing the repository to hand over the raw body instead would
    /// move the envelope check after the decode, and a `{success: false}` body
    /// would then be answered as a decode failure rather than as the server's own
    /// refusal.
    static func read(_ document: JSONValue) -> Result<ThreadPage, ApiError> {
        guard let bytes = try? JSONWire.encode(document),
              let typed = try? JSONDecoder().decode(TimelineResponse.self, from: bytes)
        else {
            return readShapeGuarded(document)
        }
        return .success(page(from: typed))
    }

    /// The typed projection: ``TimelineResponse`` to ``ThreadPage``.
    ///
    /// ⚠️ IT DROPS ROWS TOO, ON THE SAME TWO GROUNDS AS THE FALLBACK. A DTO that
    /// decoded is not a DTO whose every row can be rendered: `id` and `timestamp`
    /// are non-Optional here, but the server can still send them EMPTY, and an
    /// empty id is not a list key. Counting those keeps ``ThreadPage`` meaning the
    /// same thing whichever path produced it.
    private static func page(from response: TimelineResponse) -> ThreadPage {
        var events: [ThreadEvent] = []
        var dropped = 0
        for row in response.timeline {
            if let event = event(from: row) {
                events.append(event)
            } else {
                dropped += 1
            }
        }

        return ThreadPage(
            events: events,
            cursor: cursor(from: response.pageInfo),
            // ⛔ `?? false`. See the ⛔ on ``ThreadPage/hasMore``.
            hasMore: response.pageInfo?.hasMore ?? false,
            droppedEventCount: dropped
        )
    }

    /// nil for a row that cannot be identified or placed in time.
    ///
    /// ⛔ NO DEFAULTING BEYOND WHAT THE FALLBACK DOES, AND THE ABSENCES ARE NOT
    /// THE SAME THING. The fallback maps an ABSENT `type` to `sms`; here `type`
    /// is required, so a row that omits it never reaches this function at all —
    /// the whole document fails typed decode and the fallback handles it. What
    /// this must not do is additionally rewrite an EMPTY `type` to `sms`, because
    /// the fallback does not, and the two paths have to agree value for value on
    /// every document that decodes.
    private static func event(from row: TimelineEvent) -> ThreadEvent? {
        guard !row.id.isEmpty, !row.timestamp.isEmpty else { return nil }

        return ThreadEvent(
            id: row.id,
            type: row.type,
            direction: row.direction,
            timestamp: row.timestamp,
            body: row.body,
            status: row.status,
            subject: row.subject,
            mediaUrls: row.mediaUrls ?? [],
            durationSeconds: row.duration,
            summary: row.summary,
            hasTranscript: row.hasTranscript ?? false
        )
    }

    /// The cursor for the window before this one, read off the typed page info.
    ///
    /// ⛔ BOTH HALVES OR NOTHING, for the reason spelled out on the `JSONValue`
    /// overload below: `beforeId` without `before` is a 400 from the route, and
    /// both fields are null together on an empty page.
    private static func cursor(from pageInfo: TimelinePageInfo?) -> ThreadCursor? {
        guard let before = pageInfo?.oldest, !before.isEmpty,
              let beforeId = pageInfo?.oldestId, !beforeId.isEmpty
        else {
            return nil
        }
        return ThreadCursor(before: before, beforeId: beforeId)
    }

    /// The shape-guarded fallback, for a document ``TimelineResponse`` refuses.
    ///
    /// ⛔ REACHED ONLY FROM ``read(_:)``'s failure branch, and kept because a
    /// deployed origin can lag the fixture corpus. Every field is read through an
    /// accessor that answers nil rather than throwing, so no single unexpected
    /// value can take out the thread.
    static func readShapeGuarded(_ document: JSONValue) -> Result<ThreadPage, ApiError> {
        // ⛔ A MISSING `timeline` KEY IS A MALFORMED RESPONSE, NOT AN EMPTY
        // THREAD. The route builds the key unconditionally on its success path
        // (`{success: true, timeline: events}`), and an empty thread is `[]` —
        // so absence means the body is not the one this route sends, and
        // rendering it as "no messages yet" would show an empty conversation for
        // a customer who has one.
        guard let rows = document["timeline"]?.arrayValue else {
            return .failure(.decoding("TimelineResponse success response carried no timeline array"))
        }

        var events: [ThreadEvent] = []
        var dropped = 0
        for row in rows {
            if let event = event(from: row) {
                events.append(event)
            } else {
                dropped += 1
            }
        }

        return .success(ThreadPage(
            events: events,
            cursor: cursor(from: document["pageInfo"]),
            // ⛔ `?? false`. See the ⛔ on ``ThreadPage/hasMore``.
            hasMore: document["pageInfo"]?["hasMore"]?.boolValue ?? false,
            droppedEventCount: dropped
        ))
    }

    /// nil when the row cannot be identified or placed in time, which are the two
    /// things a thread entry cannot be rendered without.
    ///
    /// ⚠️ EVERY OTHER FIELD DEGRADES RATHER THAN REJECTS. A row with no `body` is
    /// a legitimate empty message; a row with no `id` cannot be a list key and a
    /// row with no `timestamp` cannot be ordered, and inventing either would put
    /// a message in the wrong place in someone's conversation.
    private static func event(from row: JSONValue) -> ThreadEvent? {
        guard let id = row["id"]?.stringValue, !id.isEmpty,
              let timestamp = row["timestamp"]?.stringValue, !timestamp.isEmpty
        else {
            return nil
        }

        return ThreadEvent(
            id: id,
            // ⚠️ The server always writes these two, but a defaulted string is
            // still better than a dropped row: an unlabelled message is
            // readable, an absent one is not.
            type: row["type"]?.stringValue ?? ThreadEventKind.sms,
            direction: row["direction"]?.stringValue ?? ThreadEventDirection.inbound,
            timestamp: timestamp,
            body: row["body"]?.stringValue ?? "",
            status: row["status"]?.stringValue ?? "",
            subject: row["subject"]?.stringValue,
            // ⚠️ `compactMap`, so a non-string element is skipped rather than
            // taking out the whole attachment list. The column is `Json?` and
            // the server filters it to strings on the way out, but this reads a
            // shape nothing in the database enforces.
            mediaUrls: row["mediaUrls"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            durationSeconds: row["duration"]?.integerValue,
            summary: row["summary"]?.stringValue,
            hasTranscript: row["hasTranscript"]?.boolValue ?? false
        )
    }

    /// The cursor for the window before this one.
    ///
    /// ⛔ BOTH HALVES OR NOTHING, WHICH IS WHY ``ThreadCursor`` CANNOT HOLD ONE.
    /// `beforeId` without `before` is a **400** from the route — an id alone
    /// cannot say which timestamp it breaks a tie at — so a half-populated
    /// `pageInfo` (both are nullable, and both are null on an empty page) must
    /// produce no cursor rather than half of one.
    private static func cursor(from pageInfo: JSONValue?) -> ThreadCursor? {
        guard let before = pageInfo?["oldest"]?.stringValue, !before.isEmpty,
              let beforeId = pageInfo?["oldestId"]?.stringValue, !beforeId.isEmpty
        else {
            return nil
        }
        return ThreadCursor(before: before, beforeId: beforeId)
    }
}
