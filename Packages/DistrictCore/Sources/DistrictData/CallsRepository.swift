import DistrictModel
import DistrictNetwork
import Foundation

/// The call log, plus the per-call reads a detail screen makes on demand.
public struct CallsRepository: Sendable {
    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    /// A pager over the call log, newest first.
    ///
    /// ⛔ NO TOTAL, SO END-OF-LIST IS INFERRED FROM A SHORT PAGE. The route
    /// answers a BARE ARRAY with no `total`, no `hasMore` and no cursor. That is
    /// what ``OffsetPage/total`` being nil expresses, and it costs one extra empty
    /// request on an exactly-divisible feed — the right price for not guessing.
    ///
    /// ⛔ `[CallSummary].self`, WITH NO WRAPPER. `NextResponse.json(calls)` is
    /// what the route does; a DTO expecting `{success, …}` fails to decode every
    /// response it sends. This is one of three bare-array routes and the only one
    /// on the MVP surface — see ``BareArrayEndpoints``.
    ///
    /// ⚠️ A NEW PAGER PER WORKSPACE. Switching workspace must produce a new one
    /// rather than resetting this: the dedup set and the offsets are only
    /// meaningful within one tenant.
    ///
    /// ⚠️ THE DEDUP KEY IS NOW THE DTO'S OWN NON-OPTIONAL `id` rather than a
    /// lookup into an untyped document, so the identify closure can no longer be
    /// silently wrong about which field identifies a row.
    public func pager(workspaceId: String) -> OffsetPager<CallSummary> {
        let client = client
        return OffsetPager(
            identify: { $0.id },
            fetch: { limit, offset in
                let descriptor = DistrictEndpoints.calls(
                    workspaceId: workspaceId,
                    limit: limit,
                    offset: offset
                )
                return await client.send(descriptor, as: [CallSummary].self)
                    .map { OffsetPage(items: $0, total: nil) }
            }
        )
    }

    /// The newest inbound calls, unpaged, for the dialer's call-back list.
    ///
    /// ⛔ NOT ``pager(workspaceId:)`` READ ONCE, AND THE DIFFERENCE IS NOT STYLE.
    /// An ``OffsetPager`` is a stateful object whose dedup set and offsets belong
    /// to one scrolling surface; borrowing one to read twenty rows would give the
    /// dialer a second pager over the same feed, advancing independently of the
    /// call log's. This is one GET with a small `limit`, which is what the
    /// endpoint is for.
    ///
    /// ⛔ IT REUSES THE CALL-LOG ENDPOINT BECAUSE THE SERVER HAS NO `direction`
    /// FILTER. One page is asked for and its inbound rows are kept client-side, so
    /// there is no new route, no new descriptor and no new fixture.
    ///
    /// ⛔ INBOUND ROWS ONLY, AND THE FILTER IS LOAD-BEARING RATHER THAN TIDY.
    /// ``CallSummary/from`` is the raw `Call.from` column, which on an OUTBOUND row
    /// is the workspace's OWN number: the dial route writes `from: fromNumber` and
    /// puts the callee in `callerName`. A "redial" built from `from` on an outbound
    /// row would dial the workspace's own line, connect, bill, and read as a
    /// carrier fault rather than as a bug in this list. A row with NO `direction`
    /// at all is excluded for the same reason, because an unknown direction is not
    /// evidence that `from` is a callee.
    ///
    /// ⚠️ SO THIS IS "CALL THEM BACK", NOT "REDIAL", AND THE UI MUST SAY SO. A
    /// screen labelled redial would promise to repeat outbound calls it cannot
    /// repeat.
    ///
    /// ⚠️ THE ROWS ARE NOT DEDUPLICATED BY NUMBER. One person who called three
    /// times is three rows, each with its own time and outcome, and collapsing them
    /// here would misreport the log. A view may collapse them for display, and that
    /// is the view's decision to comment.
    ///
    /// ⚠️ NO ENVELOPE TO CHECK, because the feed is a bare array, and an EMPTY
    /// result is a legitimate "nobody has called in" rather than a failure: a
    /// workspace whose last twenty calls were all outbound reaches it honestly. No
    /// guard could tell that apart from a broken read anyway.
    public func recentCallbacks(
        workspaceId: String,
        limit: Int = CallsRepository.callbackLimit
    ) async -> Result<[CallSummary], ApiError> {
        let descriptor = DistrictEndpoints.calls(workspaceId: workspaceId, limit: limit, offset: 0)
        return await client.send(descriptor, as: [CallSummary].self)
            .map { rows in rows.filter(CallsRepository.isCallable) }
    }

    /// One call, fetched by id.
    ///
    /// ⚠️ THE DETAIL SCREEN FETCHES RATHER THAN RECEIVING THE ROW, which is what
    /// makes it survive process death and be openable from a push notification,
    /// where an id is all the app has.
    ///
    /// ⚠️ A 404 DOES NOT IMPLY A MALFORMED ID: the server reads by id and checks
    /// ownership afterwards, so another tenant's id looks exactly like one that
    /// does not exist. Word any message accordingly.
    ///
    /// ⚠️ THE PAYLOAD IS THE FEED'S OWN ``CallSummary``, not a richer type — the
    /// route reuses the server's one `toCallSummaries` mapping. What differs is
    /// the ENVELOPE: the feed is a bare array, this is `{success, call}`.
    public func detail(workspaceId: String, callId: String) async -> Result<CallSummary, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.callDetail(workspaceId: workspaceId, callId: callId),
            as: CallDetailResponse.self
        )
        return outcome.flatMap { response in
            ResponseEnvelope.affirm("CallDetailResponse", response.success, response).flatMap { affirmed in
                // ⚠️ A 2xx WITH NO `call` IS MALFORMED, NOT AN ABSENCE. Absence
                // is the 404 above; reporting this as one would hide a server
                // bug behind an ordinary empty state.
                guard let call = affirmed.call else {
                    return .failure(.decoding("CallDetailResponse success response carried no call"))
                }
                return .success(call)
            }
        }
    }

    /// A call's transcript.
    ///
    /// ⛔ THE ENVELOPE MATTERS MOST ON THIS ONE, because `""` is the LEGITIMATE
    /// value for a call with no transcript. Without the flag, a structurally wrong
    /// 200 is indistinguishable from "nothing was said" and the screen renders an
    /// empty transcript for a call that has one.
    ///
    /// ⚠️ PREFER THIS OVER THE COPY ON THE FEED ROW. ``CallSummary/transcript``
    /// arrives populated, but a transcript can be written after a call ends, so
    /// the embedded copy is only as fresh as the request that fetched the row.
    public func transcript(workspaceId: String, callId: String) async -> Result<String, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.callTranscript(workspaceId: workspaceId, callId: callId),
            as: CallTranscriptResponse.self
        )
        return outcome
            .flatMap { ResponseEnvelope.affirm("CallTranscriptResponse", $0.success, $0) }
            // ⚠️ An absent transcript is "" rather than nil — the handler does
            // `call.transcript || ""`, so emptiness is the "nothing to show"
            // test and a nil check would never fire.
            .map(\.transcript)
    }

    /// A playable URL for a call's recording.
    ///
    /// ⛔ RESOLVE THIS AT THE MOMENT OF PLAYBACK AND DO NOT STORE IT. The server
    /// redirects to a short-lived presigned object URL; a cached one expires and
    /// fails silently in whatever player receives it, at which point the failure
    /// looks like a broken recording rather than a stale link.
    ///
    /// ⛔ AND THE REDIRECT IS NOT FOLLOWED — see
    /// ``ApiClient/redirectTarget(_:)``. Following it downloads the whole audio
    /// file through this process just to learn its address.
    ///
    /// ⚠️ A call with no recording answers 404, which is an ordinary state for a
    /// missed call rather than an error worth an alarming message.
    public func recordingURL(workspaceId: String, callId: String) async -> Result<String, ApiError> {
        let descriptor = DistrictEndpoints.callRecordingUrl(workspaceId: workspaceId, callId: callId)
        return await client.redirectTarget(descriptor).map(\.location)
    }

    /// One page, because the filtering happens afterwards.
    ///
    /// ⚠️ SMALL ON PURPOSE. The server has no `direction` filter, so the whole
    /// list is whatever is inbound within the newest twenty rows, which is one
    /// server page and comfortably under the route's clamp of 100. Asking for more
    /// would buy a longer list for a screen that is a shortcut rather than a log.
    public static let callbackLimit = 20

    /// The ``CallSummary/direction`` value whose ``CallSummary/from`` is somebody
    /// else's number.
    ///
    /// ⚠️ `direction`, NOT ``CallSummary/type``. The handler derives `type` from
    /// the normalised status as well, so an unanswered inbound call reads `missed`
    /// there and would be dropped by a filter that used it.
    ///
    /// ⚠️ DELIBERATELY NOT ``ThreadEventDirection/inbound``, WHICH HOLDS THE SAME
    /// STRING. That is the timeline mapper's vocabulary for a different column, and
    /// sharing a constant between two surfaces that merely agree today makes one of
    /// them unable to move without the other. Kotlin's `CallsRepository` declares
    /// its own for the same reason.
    private static let inboundDirection = "inbound"

    /// ⛔ BLANK COUNTS AS ABSENT, matching Kotlin's `isNullOrBlank`. A row whose
    /// number is whitespace is not something to call back, and a list given one
    /// would offer a row that fills the keypad with nothing.
    ///
    /// ⛔ AND SO DOES AN ENGLISH SENTENCE, WHICH IS WHAT BLANKNESS ALONE MISSED.
    /// A withheld caller reaches this filter as the literal `"Inbound SIP
    /// Caller"` rather than as an empty string (see ``CallerIdentity``), which is
    /// not blank, so the row was offered and tapping it typed that sentence into
    /// the keypad. ``CallerIdentity/resolved(_:)`` subsumes the blank rule, so
    /// this is one test rather than two.
    private static func isCallable(_ row: CallSummary) -> Bool {
        guard row.direction == inboundDirection else { return false }
        return CallerIdentity.resolved(row.from) != nil
    }
}
