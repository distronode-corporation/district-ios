import DistrictModel
import DistrictNetwork
import Foundation

/// One page of the meetings history, and how much of one it is.
///
/// ⛔ A PAGE RATHER THAN AN ARRAY, BECAUSE AN EMPTY ARRAY HERE HAS THREE DIFFERENT
/// MEANINGS AND ONLY ONE OF THEM IS "there are no meetings". The server caps the
/// query at 50 rows BEFORE this client drops any, so a workspace whose 50 most
/// recent rows are all `video_` avatar sessions receives a full page and renders
/// nothing from it. That is the same shape as an empty workspace list shown to a
/// paying customer, and ``FailureText``'s own ⛔ is the rule it breaks: "we could
/// not look" and "there is nothing" must not share a representation. Neither must
/// "the page we were given held none we draw".
///
/// ⛔ THE CAP IS SERVER-SIDE AND CANNOT BE FIXED FROM HERE. `GET
/// /api/district/meetings` runs `take: 50` inside its own query and the response
/// carries no total, no cursor and no flag, so there is nothing on the wire to ask.
/// The real repair is on the server (filter before the cap, or publish a cursor);
/// this type only makes the client stop presenting a truncated page as a confident
/// absence. See the ⚠️ on ``MeetingsRepository/meetings(workspaceId:)``.
public struct MeetingsPage: Sendable {
    /// The rows a screen should draw, newest first.
    ///
    /// ⚠️ NO EXPLICIT INITIALISER, LIKE ``MessageSearchResults``. A public struct's
    /// synthesised memberwise initialiser is INTERNAL, so only this module can build
    /// one, which is correct here: the only honest producer is
    /// ``MeetingsRepository/meetings(workspaceId:)``, and a page assembled anywhere
    /// else could claim a ``receivedCount`` no server ever sent.
    public let meetings: [MeetingSummary]

    /// How many rows the SERVER sent, before anything here dropped one.
    ///
    /// ⚠️ THE ONLY EVIDENCE THERE IS. It is a count of a page, never of the history:
    /// the route publishes no total.
    public let receivedCount: Int

    /// The server's own page size.
    ///
    /// ⛔ A NUMBER COPIED FROM ANOTHER CODEBASE, WHICH IS A DRIFT HAZARD AND IS
    /// STATED AS ONE. `take: 50` is a literal in the route with nothing on the wire
    /// echoing it, so raising it there leaves this saying 50 and ``isCapped``
    /// under-reporting rather than over-reporting. Under-reporting is the safe
    /// direction (a caption goes missing, no false claim is made), which is why the
    /// duplication is tolerable until the route publishes a cursor.
    public static let serverPageLimit = 50

    /// ⚠️ THE PAGE ARRIVED FULL, SO THERE MAY BE OLDER MEETINGS THIS READ CANNOT SEE.
    /// A screen must caption the list rather than present it as the whole history.
    /// `>=` rather than `==` so a raised server cap degrades to "capped" instead of
    /// silently answering false.
    public var isCapped: Bool {
        receivedCount >= MeetingsPage.serverPageLimit
    }

    /// ⛔ TRUE MEANS "this page held nothing we draw", WHICH IS NOT "there are no
    /// meetings" AND MUST NOT BE WORDED AS ONE. Rows arrived and every one of them
    /// belonged to another product surface; the workspace may well have a full
    /// history sitting behind the cap.
    public var isEmptyAfterFiltering: Bool {
        meetings.isEmpty && receivedCount > 0
    }
}

/// Reading back the meetings the voice agent's Companion wrote up.
///
/// ⛔ NEITHER ROUTE CARRIES AN ENVELOPE AND THE TWO DO NOT EVEN SHARE A TOP-LEVEL
/// SHAPE, so neither goes through ``ResponseEnvelope`` and that is a decision
/// rather than an omission. The list answers a BARE ARRAY, the detail answers a
/// BARE OBJECT (the raw row), and there is no `success` flag on either to check;
/// an empty list is a legitimate "nothing yet" that no guard could distinguish
/// from a broken read anyway. `MeetingsRepositoryTests` asserts a body with no
/// `success` decodes cleanly, so the absence is pinned rather than assumed.
///
/// ⛔ THE LIST EXCLUDES `video_` ROOMS AND NOTHING ELSE, AND IT USED TO BE THE
/// OTHER WAY ROUND. It kept only `meet_` rooms, which reads as the same rule and
/// is not, because `Meeting.roomName` has a THIRD prefix: the scheduling webhook
/// writes `sched_<workspaceId>_<bookingId>` with a title, a summary, a
/// transcript and participants. So every meeting booked through the scheduler
/// was dropped here while the web listed it. An allowlist stated the intent
/// ("not the avatar sessions") in a form that silently excluded whatever nobody
/// had thought of yet, and would do it again to a fourth prefix; the exclusion
/// is now the thing that is actually meant, written once.
///
/// ⛔ WHAT IS EXCLUDED IS A DIFFERENT PRODUCT SURFACE, NOT BAD DATA. The
/// `Meeting` table records whatever room the Companion was dispatched into,
/// which includes `video_` avatar sessions: a billable Tavus product with its
/// own billing story, whose rows would appear here as meetings the user never
/// held. A row that fails the filter belongs to something else; it is not
/// corrupt and it is not an error, so the rest of the page is still served.
/// ⚠️ THE CHECK IS A PREFIX TEST AND NOT ``RoomName``, on purpose: that type
/// additionally restricts the suffix to `[a-zA-Z0-9-]` to match the web lobby,
/// while the server's own regex ends in `.+` and admits underscores — so a real
/// room like `meet_ws-contract-test_standup` is a valid name this client must
/// READ and would refuse to MINT. Validating a name we did not construct against
/// the minting rule would hide live meetings from their own list. It is also why
/// that type cannot be the filter at all now: a `sched_` room is not one this
/// client would ever mint, and every initialiser on it refuses one.
///
/// ⛔ NO CACHE, AND FOR THE READS THAT IS THE ORDINARY REASON: the list is what
/// someone checks right after a meeting ends, and a stale copy answers "where
/// are my minutes" with a snapshot from before they existed.
///
/// ⛔ NOTHING HERE MINTS A ROOM TOKEN. Joining is a separate capability — a
/// signed, short-lived credential whose guest invite is transferable for twelve
/// hours — and it does not belong on the type that reads the archive.
public struct MeetingsRepository: Sendable {
    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    /// The workspace's meetings, newest first.
    ///
    /// ⛔ `[MeetingSummary].self`, WITH NO WRAPPER. `NextResponse.json(results)`
    /// is what the route does; a DTO expecting `{success, …}` fails to decode
    /// every response it sends. This is one of the three bare-array routes — see
    /// ``BareArrayEndpoints``.
    ///
    /// ⛔ THE SERVER CAPS THIS AT 50 AND APPLIES THE CAP BEFORE THIS CLIENT FILTERS,
    /// WHICH IS THE COMPOUNDING FAULT AND IS NOT FIXABLE FROM HERE. The route runs
    /// `take: 50` inside its own Prisma query, ordered by `createdAt` desc, and the
    /// exclusion below then removes rows from whatever those 50 happened to be. So a
    /// busy workspace whose 50 most recent rows are all `video_` sessions receives a
    /// FULL page and renders an EMPTY list, while the browser shows a full one. The
    /// repair belongs on the server (filter before the cap, or publish a cursor and
    /// let this page through it); nothing on the wire carries a total, a cursor or a
    /// flag, so there is not even a question this client could ask.
    ///
    /// ⚠️ WHAT IS DONE HERE INSTEAD IS TO STOP THE TRUNCATION READING AS AN ABSENCE.
    /// ``MeetingsPage`` carries the count the server sent alongside the rows kept, so
    /// a screen can tell "there are no meetings" from "this page held none we draw"
    /// and from "there may be older ones behind the cap". See the ⛔ on that type.
    public func meetings(workspaceId: String) async -> Result<MeetingsPage, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.meetings(workspaceId: workspaceId),
            as: [MeetingSummary].self
        )
        return outcome.map { rows in
            MeetingsPage(
                meetings: rows.filter { !$0.roomName.hasPrefix(RoomName.billableAvatarPrefix) },
                receivedCount: rows.count
            )
        }
    }

    /// One meeting in full.
    ///
    /// ⛔ NO ENVELOPE HERE EITHER — the route returns the raw row, so there is no
    /// `success` flag and a 404 arrives as an ``ApiError`` rather than as a body.
    /// ⚠️ That 404 is also what a meeting id from ANOTHER workspace produces,
    /// because the lookup is scoped on both id and workspaceId: "not yours" and
    /// "not there" are deliberately indistinguishable, so any message about it
    /// has to be worded for both.
    ///
    /// ⛔ THE DETAIL IS NOT A SUPERSET OF THE LIST ROW. It carries `summary` and
    /// `participants` where the list carried `summaryPreview` and
    /// `participantCount`, so neither model decodes the other's payload and a
    /// screen cannot promote a list row into a detail one without this call.
    public func detail(workspaceId: String, meetingId: String) async -> Result<MeetingDetail, ApiError> {
        await client.send(
            DistrictEndpoints.meetingDetail(workspaceId: workspaceId, meetingId: meetingId),
            as: MeetingDetail.self
        )
    }
}
