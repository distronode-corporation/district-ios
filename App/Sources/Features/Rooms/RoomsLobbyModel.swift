import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import Observation

/// The meetings history's own state.
///
/// ⛔ DECLARED AT FILE SCOPE RATHER THAN NESTED, for the reason `AnalyticsModel.swift`
/// records: a nested type whose NAME matches an associated-type requirement of a
/// protocol the enclosing type conforms to becomes the WITNESS for it, and the error
/// surfaces somewhere else entirely.
enum MeetingsListState {
    case loading
    /// ⚠️ EMPTY IS A SUCCESS AND IS THE ORDINARY CASE ON DAY ONE. A workspace that
    /// has held no meetings renders an explanatory empty state, never a failure;
    /// telling a new customer something is broken on the screen they were sent to
    /// first is the failure this distinction exists to prevent.
    ///
    /// ⛔ AND IT CARRIES A ``MeetingsPage`` RATHER THAN AN ARRAY, BECAUSE AN EMPTY
    /// SUCCESS IS NOT ONE ANSWER. The server caps its query at 50 rows before this
    /// client drops the avatar sessions, so an empty array can mean "there are no
    /// meetings" or "the page we were given held none we draw" — and the second one
    /// happens to a BUSY workspace, which is the opposite of what the day-one
    /// sentence says. The page is what lets the screen tell them apart; see the ⛔ on
    /// ``MeetingsPage``.
    case ready(MeetingsPage)
    case failed(FailureText)
}

/// One meeting's full record, while its sheet is open.
///
/// ⚠️ A SEPARATE READ FROM THE LIST, because the two routes return different SHAPES
/// rather than a subset: the list publishes a 220-character `summaryPreview` and a
/// participant COUNT, the detail publishes the whole summary, the transcript and the
/// action items. `MeetingResponses.swift` states it as a ⛔ on both types. Nothing in
/// a list row could be reused to populate this.
enum MeetingRecordState {
    case loading
    case ready(MeetingDetail)
    /// ⚠️ A 404 HERE MEANS "not yours OR not there", indistinguishably. The route
    /// scopes its lookup on both the id and the workspace, so another tenant's
    /// meeting is simply not found, and the wording must not promise which.
    case failed(FailureText)
}

/// The rooms lobby: what has already happened in this workspace, and how to start the
/// next one.
///
/// ⛔ NO ENGINE HERE, WHICH IS THE SAME CALL THE KOTLIN LOBBY MAKES. An engine owns a
/// socket and a claim on the device's audio route, and constructing one before
/// anybody has decided to join would take audio focus from whatever the user is
/// listening to. The engine belongs to ``ActiveRoomModel``.
///
/// ⛔ THE HISTORY AND THE JOIN FORM ARE INDEPENDENT, AND THE FORM MUST SURVIVE A
/// FAILED HISTORY READ. They are two unrelated server surfaces: the list is
/// `GET /api/district/meetings` and the join needs only a name and a token. A screen
/// that hid the field behind a successful list read would turn an outage of the
/// minutes archive into an inability to hold a meeting.
///
/// ⛔ THE ROOM NAME IS MINTED THROUGH ``RoomName`` AND NOWHERE ELSE. A string template
/// here would be one character from `video_`, which is a BILLABLE Tavus avatar
/// session with a default concurrency ceiling of one, so the first accidental one is
/// both a charge and an outage of the avatar feature for every other room.
@MainActor
@Observable
final class RoomsLobbyModel {
    private(set) var meetings: MeetingsListState = .loading

    /// What the user typed, verbatim.
    ///
    /// ⚠️ HELD RAW AND NORMALISED SEPARATELY, DELIBERATELY. Rewriting the field's own
    /// text as somebody types moves their cursor and eats their spaces; showing them
    /// ``normalizedName`` beside it tells them what the room will actually be called.
    /// A field that silently rewrote "Weekly Review" at submit time would leave two
    /// people unable to explain why they are in different rooms.
    var roomName = ""

    /// The meeting whose record is open, or nil.
    ///
    /// ⛔ A SHEET ON THIS SCREEN RATHER THAN A DESTINATION OF ITS OWN, AND THAT IS A
    /// DELIBERATE NARROWING. The detail route returns the meeting's COMPLETE
    /// TRANSCRIPT, every word everybody said, unredacted. A destination would put
    /// that behind a route that survives process death and sits in the back stack, so
    /// a phone left on a desk redisplays it on resume. A sheet is dismissed with the
    /// screen and holds nothing across a kill.
    private(set) var record: MeetingRecordState?

    /// Mirrors nothing on the server, and gates CREATION only.
    ///
    /// ⛔ STARTING A ROOM IS GATED, ATTENDING ONE IS NOT, AND THE SPLIT IS DELIBERATE.
    /// The rule is a role gate on anything that STARTS or ENDS a room, and
    /// `WorkspaceRole.allowsMutation` is what expresses it. Attendance is a different
    /// question: a viewer's token carries `canPublish:false`, so the media server
    /// already refuses their microphone and camera, and the room is still a
    /// legitimate seat for them. So the start form is hidden with a sentence and
    /// Rejoin stays offered. ⚠️ AN AFFORDANCE, NOT A SECURITY CONTROL, and it errs
    /// low: a nil role means "the role could not be established", never "assume
    /// client".
    let canStart: Bool

    private let repository: MeetingsRepository
    private let workspaceId: String

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        canStart = WorkspaceRole.allowsMutation(role)
        repository = container.meetings
        self.workspaceId = workspaceId
    }

    /// The `meet_` suffix ``roomName`` will become. Empty when nothing usable was
    /// typed.
    var normalizedName: String {
        RoomName.normalizeSuffix(roomName)
    }

    /// ⛔ FALSE FOR AN EMPTY SUFFIX RATHER THAN LETTING THE SERVER REFUSE IT.
    /// `meet_<ws>_` fails the route's own `^(meet|video)_([a-zA-Z0-9-]+)_(.+)$` and
    /// comes back as a 400 "Invalid meeting room format", which reads as a server
    /// fault for what is really an empty field.
    var canJoin: Bool {
        canStart && !normalizedName.isEmpty
    }

    /// The full room name to navigate with, or nil when nothing usable was typed.
    ///
    /// ⛔ RETURNS THE WHOLE `meet_<ws>_<suffix>` NAME RATHER THAN THE SUFFIX, so the
    /// destination carries a self-describing value: a room screen restored after
    /// process death holds the exact name the token was minted for, with no second
    /// chance to assemble it differently. `Route.activeRoom`'s own ⛔ says so.
    func roomToStart() -> RoomName? {
        guard canStart else { return nil }
        return RoomName(workspaceId: workspaceId, suffix: roomName)
    }

    /// Rejoin a meeting that is still running.
    ///
    /// ⛔ ONLY MEANINGFUL FOR AN `in-progress` ROW, AND THE SCREEN IS WHAT ENFORCES
    /// THAT. Joining the room of a COMPLETED meeting is not an error server-side (the
    /// name is still valid and a fresh empty room would be created), but it would
    /// silently start a SECOND meeting under the name whose minutes the user was
    /// reading, and the Companion would write those up too.
    ///
    /// ⛔ `RoomName(joining:)`, NOT `RoomName(_:)`. A stored `Meeting.roomName` is a
    /// three-part name carrying the workspace separator, which the minting-strictness
    /// initialiser refuses on purpose; that type's own docs carry the distinction.
    func roomToRejoin(_ storedName: String) -> RoomName? {
        RoomName(joining: storedName)
    }

    /// Read the meetings history.
    ///
    /// - Parameter refreshing: ⚠️ TRUE KEEPS THE ROWS ON SCREEN, the same call every
    ///   list in this app makes: a re-read would otherwise blank a list somebody is
    ///   reading in order to redraw almost the same thing.
    func load(refreshing: Bool = false) async {
        if !refreshing {
            meetings = .loading
        }
        switch await repository.meetings(workspaceId: workspaceId) {
        case let .success(page):
            meetings = .ready(page)
        case let .failure(error):
            meetings = .failed(FailureText.from(error))
        }
    }

    /// Open one meeting's full record.
    ///
    /// ⛔ RE-READ ON EVERY OPEN, NEVER CACHED. A meeting still running has no minutes
    /// yet, and the whole point of coming back to it is that the Companion has since
    /// written them; a cached copy would answer "where are my minutes" with the
    /// snapshot from before they existed.
    ///
    /// ⚠️ THE LOADING STATE IS SET BEFORE THE REQUEST so the sheet opens immediately.
    /// Waiting for the response would make a tap on a slow connection look like it
    /// did nothing, and the second tap would issue a second read.
    func openMeeting(_ meetingId: String) async {
        record = .loading
        let outcome = await repository.detail(workspaceId: workspaceId, meetingId: meetingId)
        // ⚠️ DROPPED IF THE SHEET WAS CLOSED WHILE THE READ WAS IN FLIGHT. Writing it
        // anyway would reopen a transcript the user had just dismissed.
        guard record != nil else { return }
        switch outcome {
        case let .success(detail):
            record = .ready(detail)
        case let .failure(error):
            record = .failed(FailureText.from(error))
        }
    }

    func closeMeeting() {
        record = nil
    }
}
