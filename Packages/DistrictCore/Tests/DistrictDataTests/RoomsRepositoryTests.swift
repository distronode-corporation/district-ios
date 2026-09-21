import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The one call that hands out a room credential.
///
/// ⛔ EVERY BODY HERE CARRIES `success`, UNLIKE THE MEETINGS BODIES NEXT DOOR. The
/// two meetings routes publish no envelope at all and `MeetingsRepositoryTests`
/// asserts that; this route does publish one, and the affirm is what stops a join
/// against a token the server declined to stand behind.
final class RoomsRepositoryTests: XCTestCase {
    // MARK: - The happy path

    func testMintingATokenPostsTheRoomNameAndTheConstantIdentity() async throws {
        let transport = RepositoryTransport(json: RoomBodies.token())
        let room = try XCTUnwrap(RoomName(workspaceId: "ws-1", suffix: "standup"))

        let result = await RoomsRepository(client: .repositoryTest(transport)).token(roomName: room)

        XCTAssertEqual(result.successOnly?.token, "contract-livekit-room-jwt")
        XCTAssertEqual(transport.requests.first?.method, .post)
        XCTAssertEqual(transport.requestedURLs.first, "https://www.distronode.com/api/district/calls/token")
        XCTAssertEqual(
            transport.bodies.first,
            #"{"identity":"ios","roomName":"meet_ws-1_standup"}"#
        )
    }

    /// ⛔ THE URL IS THE SERVER'S CHOICE OF MEDIA NODE AND IS CARRIED VERBATIM. The
    /// room only exists on the deployment that created it, so a client that derived
    /// one from the workspace's region would join a bus that has never heard of the
    /// room — and would do it silently.
    func testTheMediaUrlIsCarriedThroughUntouched() async throws {
        let transport = RepositoryTransport(json: RoomBodies.token(url: "wss://livekit-eu.distronode.com"))
        let room = try XCTUnwrap(RoomName(joining: "meet_ws-1_standup"))

        let result = await RoomsRepository(client: .repositoryTest(transport)).token(roomName: room)

        XCTAssertEqual(result.successOnly?.url, "wss://livekit-eu.distronode.com")
    }

    /// ⛔ AN ABSENT `e2ee` IS A REAL ANSWER MEANING "JOIN UNENCRYPTED", NOT A FAULT,
    /// and an absent `guestInvite`/`guestPath` is the server refusing to mint a
    /// transferable publish capability for a viewer. Both must decode.
    func testAViewerBodyWithNoKeyAndNoInviteStillDecodes() async throws {
        let transport = RepositoryTransport(json: RoomBodies.viewerToken())
        let room = try XCTUnwrap(RoomName(joining: "meet_ws-1_standup"))

        let result = await RoomsRepository(client: .repositoryTest(transport)).token(roomName: room)

        let response = try XCTUnwrap(result.successOnly)
        XCTAssertNil(response.e2ee, "no key means join unencrypted, not something went wrong")
        XCTAssertNil(response.guestPath, "a viewer is refused an invite by server decision")
        XCTAssertNil(result.failureOnly)
    }

    /// ⚠️ THE KEY IS CARRIED AS THE BASE64 TEXT AND IS NEVER DECODED. Decoding it
    /// selects a different derivation and every track becomes undecryptable noise
    /// with no error anywhere; the repository's job is to not touch it.
    func testTheEncryptionKeyIsCarriedAsTextRatherThanDecoded() async throws {
        let transport = RepositoryTransport(json: RoomBodies.token())
        let room = try XCTUnwrap(RoomName(joining: "meet_ws-1_standup"))

        let result = await RoomsRepository(client: .repositoryTest(transport)).token(roomName: room)

        XCTAssertEqual(result.successOnly?.e2ee?.key, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
    }

    // MARK: - Refusals

    /// ⛔ A 200 THAT DOES NOT AFFIRM IS A FAILURE HERE, unlike on the two meetings
    /// reads which carry no flag to check. Joining on an unaffirmed envelope means
    /// connecting to a media server with a credential the server did not stand
    /// behind.
    func testATwoHundredThatDoesNotAffirmIsAFailure() async throws {
        let transport = RepositoryTransport(json: RoomBodies.token(success: false))
        let room = try XCTUnwrap(RoomName(joining: "meet_ws-1_standup"))

        let result = await RoomsRepository(client: .repositoryTest(transport)).token(roomName: room)

        XCTAssertNil(result.successOnly)
        XCTAssertNotNil(result.failureOnly)
    }

    /// ⚠️ ANOTHER TENANT'S ROOM LANDS HERE. The server parses the workspace back out
    /// of the NAME and runs `requireWorkspaceRole` against it, so naming a room this
    /// account cannot join is a 403 rather than access to it.
    func testARefusedJoinIsAnOrdinaryHttpFailure() async throws {
        let transport = RepositoryTransport(json: #"{"error":"Forbidden"}"#, status: 403)
        let room = try XCTUnwrap(RoomName(joining: "meet_someone-else_standup"))

        let result = await RoomsRepository(client: .repositoryTest(transport)).token(roomName: room)

        XCTAssertNil(result.successOnly)
        guard case let .http(status, _)? = result.failureOnly else {
            return XCTFail("a role refusal must stay an HTTP failure")
        }
        XCTAssertEqual(status, 403)
    }
}

/// Minimal, VALID bodies for ``RoomTokenResponse``'s two branches.
///
/// ⚠️ NOT THE CONTRACT FIXTURES. `district-room-token.json` and
/// `district-room-token-viewer.json` pin the wire shape; these are the smallest
/// bodies that satisfy the Swift type, so a repository test can be about the
/// envelope and the path rather than about JSON.
enum RoomBodies {
    static func token(success: Bool = true, url: String = "wss://livekit-wss.distronode.com") -> String {
        #"""
        {"success":\#(success),"token":"contract-livekit-room-jwt","url":"\#(url)",
         "e2ee":{"key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="},
         "guestInvite":{"exp":1789000000,"sig":"c2ln"},
         "guestPath":"/meet/meet_ws-1_standup?e=1789000000&s=c2ln"}
        """#
    }

    /// ⛔ THE TWO INVITE KEYS ARE ABSENT RATHER THAN NULL, which is what the route
    /// does: it spreads them in only for a non-viewer.
    static func viewerToken() -> String {
        #"""
        {"success":true,"token":"contract-livekit-room-jwt","url":"wss://livekit-wss.distronode.com"}
        """#
    }
}
