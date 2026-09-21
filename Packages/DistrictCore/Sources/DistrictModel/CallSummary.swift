import Foundation

/// One row of `GET /api/district/calls`, of `overview.recentCalls`, and of
/// `GET /api/district/calls/{callId}` — three surfaces, one shape.
///
/// ⛔ THE FEED IS A BARE JSON ARRAY, NOT AN ENVELOPE. Almost every other
/// district route answers `{success, …}`; this one is `NextResponse.json(calls)`.
/// It is gated as `[CallSummary]` for exactly that reason, and nothing here
/// invents a wrapper.
///
/// ⛔ ONE DTO FOR THREE SURFACES BECAUSE THE SERVER USES ONE MAPPING
/// (`toCallSummaries`). The overview route's own comment calls its rows
/// "byte-identical to a row of GET /api/district/calls", and the contract suite
/// asserts the detail response equals the matching feed row. If they ever
/// diverge, three fixtures fail at once and that is the signal wanted.
///
/// ⚠️ THE HANDLER MIXES DISPLAY-FORMATTED AND RAW VALUES FOR THE SAME DATA, on
/// purpose, for two different web callers. Prefer the raw ones:
///   - ``duration`` is human text ("1m 5s"); ``durationRaw`` is seconds.
///   - ``number`` is already resolved to a contact name when one exists, falling
///     back to the phone number and then the literal "Unknown"; ``from`` is the
///     raw caller number.
///   - ``time`` is pre-formatted IN THE OPERATOR'S TIMEZONE by the server, so it
///     is not parseable as an instant. ``createdAt`` is the ISO one, and the
///     only field that may be sorted, grouped or re-formatted.
///
/// ⚠️ SIX FIELDS ARRIVE AS EXPLICIT NULLS AND THE FIXTURES CARRY THEM AS SUCH.
/// `recordingUrl`, `followUp`, `sentiment`, `disposition`, `analysis`,
/// `transferStatus` and `transferReason` are nullable columns the route passes
/// through untouched rather than omitting, which is why
/// `StrictDecodeVerifier.allowedExplicitNulls` carries an entry per row per
/// field for `district-calls.json`, `district-overview.json` and
/// `district-call-detail.json`.
public struct CallSummary: Codable, Sendable {
    public let id: String
    /// `inbound`, `outbound` or `missed`. ⚠️ NOT ``direction``: the handler
    /// derives this from the normalised status too, so a `no-answer` or `failed`
    /// call becomes `missed` whichever way it was placed.
    public let type: String
    /// Contact name if resolved, else the raw number, else the literal
    /// "Unknown".
    public let number: String
    /// The DISPLAY status from `displayCallStatus`, which downgrades a stale
    /// in-progress call — one whose terminal webhook was lost — to `no-answer`
    /// rather than showing it live forever.
    ///
    /// ⚠️ THIS IS HOW A "LIVE" BADGE IS DERIVED, with no separate flag: only a
    /// genuinely live call still reads `in-progress` or `ringing`.
    public let status: String
    /// Human-formatted, e.g. "1m 5s". ⚠️ ALWAYS EMITS A MINUTES COMPONENT
    /// ("0m 45s"), unlike `OverviewResponse.avgDurationLabel` ("45s"). Two
    /// duration formats ship in this product and they disagree on the same
    /// input; use ``durationRaw`` for arithmetic and neither of them for the
    /// other's surface.
    public let duration: String
    /// ⛔ NOT RENDERED BY THIS CLIENT, AND THE REASON IS NOT STYLE. The server
    /// formats it with `formatInUserTimezone(c.createdAt, userTimezone)` where
    /// `userTimezone` is `user.timezone || "America/Toronto"`. ⚠️ THAT COLUMN
    /// IS WRITABLE ONLY FROM THE WEB SETTINGS PAGE (`PUT /api/settings`), and
    /// THIS CLIENT DOES NOT
    /// IMPLEMENT THAT ENDPOINT — there is no descriptor for it and no screen
    /// behind one. So on iOS the value is whatever the browser last set, or the
    /// Toronto default, printed with no zone label either way: an operator in
    /// Berlin who has never opened the web app would read every call six hours off,
    /// with nothing on screen to say so.
    ///
    /// ⛔ IT IS ALSO NOT PARSEABLE, so it cannot be corrected after the fact.
    /// Render ``createdAt`` instead, which is the true instant, and let the
    /// device supply the zone the way Scheduling, Contacts and the Inbox
    /// already do. See `CallDisplay.time` in the app target.
    public let time: String
    /// ⛔ NEVER EMPTY AND OFTEN NOT A SUMMARY. See ``CallNarrative``, which is
    /// the only thing entitled to decide whether this string is one.
    public let aiSummary: String
    /// nil when the call was never recorded. ⚠️ Explicit null on the wire.
    public let recordingUrl: String?
    /// ⛔ ALWAYS `""`, AND NEVER READ. The text is not on this row (it would be
    /// the largest value on the feed); fetch it with ``CallTranscriptResponse``
    /// when a call is opened. The server keeps the KEY because older installed
    /// builds declare it non-optional, and a missing key fails synthesized
    /// decoding of the whole feed.
    public let transcript: String
    /// Whether `GET …/transcript` has a transcript to return.
    ///
    /// ⚠️ OPTIONAL although every current response carries it, so a response
    /// from a server older than the field still decodes. Read it as
    /// `hasTranscript == true`.
    public let hasTranscript: Bool?
    public let callerName: String
    /// The caller number as telephony gave it, E.164 WHEN THERE WAS ONE.
    ///
    /// ⛔ IT IS NOT ALWAYS A NUMBER. When telephony produced no caller ID the
    /// server writes an English sentence into this column instead; see
    /// ``CallerIdentity``, and run every read through it before showing or
    /// dialling this value.
    ///
    /// ⚠️ OPTIONAL EVEN THOUGH EVERY FIXTURE ROW CARRIES IT, matching the Kotlin
    /// DTO: rows that never had a number exist, and a non-optional here would
    /// fail the whole feed over one of them.
    public let from: String?
    /// `inbound` or `outbound` — the raw direction, not ``type``.
    public let direction: String?
    /// Duration in SECONDS. nil when the call never recorded one.
    public let durationRaw: Int?
    public let summary: String
    /// ISO-8601 instant. The only sortable time on this row.
    public let createdAt: String
    /// Present only when a follow-up was actually sent.
    public let followUp: CallFollowUp?
    public let sentiment: String?
    public let disposition: String?
    /// ⛔ AN OBJECT, NOT A STRING, AND THE KOTLIN DTO GOT THIS WRONG FIRST. It
    /// was typed as a string on the reasoning that the column is "unstructured",
    /// which would have thrown on every call that HAS an analysis blob. The
    /// generator's seed rows all carried `analysis: null`, so no fixture
    /// exercised it until one was pointed at a real database-backed response.
    /// The fixture now carries a populated blob precisely so this stays caught.
    public let analysis: CallAnalysis?
    /// The warm-transfer outcome, when the call was transferred at all.
    public let transferStatus: String?
    public let transferReason: String?
    /// The other party's number, described: the caller on an inbound call, the
    /// number dialled on an outbound one (where ``from`` is the workspace's own
    /// line). See ``PhoneIntel``. Optional for the same reason as
    /// ``hasTranscript``.
    public let phoneIntel: PhoneIntel?
}

// MARK: - What the server writes when it has nothing to say

/// The literals ``CallSummary/from`` and ``CallSummary/number`` carry when there
/// was no caller ID at all.
///
/// ⛔ THEY ARE ENGLISH SENTENCES IN FIELDS DOCUMENTED AS NUMBERS. The LiveKit
/// webhook writes `"Inbound SIP Caller"` and `"Outbound Campaign Caller"` into
/// the `from` COLUMN whenever `extractPhoneNumber` returns null, and its
/// room-finished branch writes `"Unknown"` the same way. The feed mapping then
/// substitutes `"Unknown"` a second time, into ``CallSummary/number`` and
/// ``CallSummary/callerName``, when nothing resolves.
///
/// ⛔ ONE SET, HERE, BECAUSE PARTIAL COPIES DRIFT. Screens that each guard a
/// different subset (only `"Unknown"` on one, only blankness on another) let a
/// withheld caller arrive as a resolved contact wearing the brand accent on some
/// screens and as a dialable row in the call-back list on another.
///
/// ⚠️ EXACT MATCHES, NOT PREFIXES OR PATTERNS, AND NOT A GUESS AT WHAT ELSE MIGHT
/// EXIST. These are the literals the server actually writes; anything else in
/// ``CallSummary/from`` is a real caller ID this client is not entitled to
/// second-guess.
public enum CallerIdentity {
    public static let placeholders: Set<String> = [
        "Inbound SIP Caller",
        "Outbound Campaign Caller",
        "Unknown",
    ]

    /// The caller this string names, or nil when it names nobody.
    ///
    /// ⚠️ nil IS THE POINT. A render site gets an absence it can style as one,
    /// and a dialler gets a value it must not offer, rather than each having to
    /// remember the list above.
    ///
    /// ⚠️ IT HANDS BACK THE TRIMMED FORM. Emptiness has to be tested after
    /// trimming anyway, so returning the original would print padding this
    /// function had already looked past.
    public static func resolved(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !placeholders.contains(trimmed) else { return nil }
        return trimmed
    }
}

/// What ``CallSummary/aiSummary`` is actually carrying.
///
/// ⛔ THE FIELD IS NEVER EMPTY, SO A BLANK CHECK ON IT CAN NEVER FIRE.
/// The feed mapping is `c.summary || "No summary available."`, and `Call.summary`
/// doubles as a marker and lifecycle channel underneath it: the dial route writes
/// `"direct:softphone"` on every outbound softphone call, and the LiveKit webhook
/// writes its own progress sentences. Rendered naively, all of them appear under
/// a heading that says "AI summary".
///
/// ⛔ AND THE MARKER IS PERMANENT. The webhook replaces a summary only when it
/// starts with `"AI Voice session"`, so `"direct:softphone"` and
/// `"AI Outbound Voice session active..."` are never overwritten by anything.
///
/// ⛔ TWO SETS, NOT ONE, BECAUSE A FAILED SUMMARY IS NOT AN ABSENT ONE. Folding
/// `"AI analysis failed to execute."` into "no summary" would report a failure as
/// an absence, which is the one thing this client is not allowed to do.
public enum CallNarrative {
    /// Nothing was ever written, or what was written is a marker or a lifecycle
    /// status rather than a summary.
    ///
    /// ⚠️ THE EM DASH IS SPELLED `\u{2014}` ON PURPOSE. It is the server's own
    /// byte (from the LiveKit webhook) and the match is exact, so a
    /// well-meant tidy of the punctuation would silently stop this entry
    /// matching and put the sentence back on screen as an AI summary.
    public static let placeholders: Set<String> = [
        "No summary available.",
        "direct:softphone",
        "AI Voice session active...",
        "AI Outbound Voice session active...",
        "Voice session completed.",
        "No answer \u{2014} no conversation took place.",
    ]

    /// A summary was attempted for this call and the attempt failed.
    ///
    /// ⛔ DISTINCT FROM ``placeholders`` AND MUST STAY SO. These are the server's
    /// AI-analysis and recording-webhook catch-branch fallbacks, which are then
    /// persisted onto the row, so the call HAS a story and this product
    /// failed to tell it. "There is nothing here" would be the wrong answer.
    public static let failures: Set<String> = [
        "Error processing audio with AI.",
        "AI analysis failed to execute.",
    ]

    /// ⚠️ THREE OUTCOMES, BECAUSE THE CARD HAS THREE HONEST THINGS TO SAY.
    public enum Summary: Equatable, Sendable {
        case text(String)
        case absent
        case failed
    }

    public static func summary(_ raw: String) -> Summary {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || placeholders.contains(trimmed) {
            return .absent
        }
        if failures.contains(trimmed) {
            return .failed
        }
        return .text(trimmed)
    }
}

/// The post-call analysis blob.
///
/// ⚠️ EVERY FIELD IS OPTIONAL, DELIBERATELY. `Call.analysis` is a Prisma `Json?`
/// column, so nothing in the database enforces this shape — the documented one
/// is `{keyPoints, objections, topics, actionItems, followUpSuggested?}`, and
/// rows written by an earlier pipeline may carry fewer keys. ⚠️ THIS DIVERGES
/// FROM KOTLIN ONLY IN SPELLING: it defaults the four lists to empty, which
/// Swift cannot express on a synthesised `Decodable` without also inventing the
/// key on re-encode — and an invented key is what the strict gate refuses.
/// Optional means "absent stays absent", which is the same leniency without the
/// round-trip lie.
public struct CallAnalysis: Codable, Sendable {
    public let keyPoints: [String]?
    public let objections: [String]?
    public let topics: [String]?
    public let actionItems: [String]?
    public let followUpSuggested: Bool?
}

/// The `followUp` object.
///
/// ⚠️ THE KEY IS `sms`, NOT `smsBody`. The underlying column is
/// `followUpSMSBody` and the handler renames it on the way out, so a DTO that
/// mirrored the column would silently model a field the wire does not carry.
public struct CallFollowUp: Codable, Sendable {
    public let email: String?
    /// ⚠️ Renamed from the column. See the type note.
    public let sms: String?
    /// ISO-8601 instant.
    public let sentAt: String?
}

/// `GET /api/district/calls/{callId}?workspaceId=`
///
/// ⛔ THE PAYLOAD IS THE FEED'S OWN ``CallSummary``, NOT A RICHER "DETAIL" TYPE.
/// The route reuses the server's `toCallSummaries` mapping deliberately.
///
/// ⚠️ THE ENVELOPE DIFFERS FROM THE FEED'S EVEN THOUGH THE PAYLOAD DOES NOT: the
/// feed is a bare ARRAY, this is `{success, call}`. A single resource needs a way
/// to say "found nothing" that a bare object cannot, so absence is a 404 with an
/// envelope — the same shape every other single-resource route here uses.
///
/// ⚠️ No transcript text rides on this payload (``CallSummary/transcript`` is
/// always empty); the text is `GET …/transcript`.
public struct CallDetailResponse: Codable, Sendable {
    public let success: Bool
    /// nil only on a malformed response. ⚠️ A genuinely missing call is a 404,
    /// and a 404 does NOT imply a malformed id: the server reads by id and
    /// checks ownership afterwards, so another tenant's call id is
    /// indistinguishable from one that never existed. Word any message
    /// accordingly.
    public let call: CallSummary?
}
