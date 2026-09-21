import DistrictModel
import DistrictNetwork
import Foundation

/// Minting the credential that joins one `meet_` room.
///
/// ⛔ ITS OWN REPOSITORY RATHER THAN A METHOD ON ``MeetingsRepository``, AND THAT
/// TYPE'S OWN ⛔ IS WHY. It says outright that nothing on it may mint a room token:
/// joining is a separate capability — a signed, short-lived credential whose guest
/// invite is a transferable twelve-hour publish right — and it does not belong on
/// the type that reads the archive. The Kotlin client did fold the two together;
/// this one deliberately does not, so that the surface which can hand out a
/// capability is one file to review rather than a method on a reader. ⚠️ It also
/// keeps the failure stories apart: a meetings list that 500s costs somebody their
/// minutes, and this failing costs them the meeting.
///
/// ⛔ NOTHING HERE MAY BE CALLED ON A REDRAW. Nothing is persisted, so the route is
/// idempotent in the sense that matters for safety — but every call mints a FRESH
/// twelve-hour guest invite, so a screen calling it per render would be minting
/// capabilities at the rate it redraws. One deliberate press, one call.
///
/// ⛔ AND NOTHING HERE MAY BE RETRIED AUTOMATICALLY, for the same reason rather than
/// for a billing one. A retry loop behind a flaky connection is an invite mill.
public struct RoomsRepository: Sendable {
    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    /// Ask for the credential that joins `roomName`.
    ///
    /// ⛔ THE ARGUMENT IS A ``RoomName`` AND NOT A `String`, WHICH IS THE `video_`
    /// GUARD RATHER THAN A TYPING PREFERENCE. `POST /api/district/calls/token`
    /// serves two structurally opposite things behind one body: a `meet_`/`video_`
    /// prefix is a standalone ROOM, and anything else is read as a `Call.id` whose
    /// caller is stamped `supervisor` — whereupon the voice agent unsubscribes their
    /// microphone and the AI greets a human it cannot hear. Only the first is
    /// reachable from this client, and it is reachable only through a type that
    /// cannot hold the billable prefix.
    ///
    /// ⛔ ENVELOPE-CHECKED, UNLIKE THE TWO MEETINGS READS NEXT DOOR. This route does
    /// publish `success`, and here the flag is worth honouring rather than ignoring:
    /// the alternative is joining a media server with a token the server declined to
    /// affirm, which presents as a room that connects and carries nothing.
    ///
    /// - Returns: `.failure` for everything else, already normalised by
    ///   ``ApiErrorNormalizer`` — a 403 for a workspace this account cannot join
    ///   (the server parses the tenant back out of the NAME and runs
    ///   `requireWorkspaceRole` against it, so another tenant's room lands here), a
    ///   400 for a name the route's own regex refuses, offline, signed out.
    public func token(roomName: RoomName) async -> Result<RoomTokenResponse, ApiError> {
        let outcome = await client.send(
            DistrictEndpoints.roomToken(roomName: roomName),
            as: RoomTokenResponse.self
        )
        return outcome.flatMap { ResponseEnvelope.affirm("RoomTokenResponse", $0.success, $0) }
    }
}
