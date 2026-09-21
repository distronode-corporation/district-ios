import ContractGateSupport
import DistrictModel
import Foundation
import XCTest

/// Per-fixture assertions for the first DTO batch — auth, native sessions and
/// workspace membership.
///
/// ⚠️ THE STRICT GATE AND THESE TESTS DO DIFFERENT JOBS AND BOTH ARE NEEDED.
/// `StrictDecodeVerifier` proves the DTO's key set matches the server's exactly;
/// it deliberately does not compare values. What it therefore cannot notice is a
/// fixture being REGENERATED against thinner data — every key still present,
/// every awkward branch gone. These tests pin the branches each fixture is
/// supposed to cover, so a regeneration that stopped exercising one fails here.
final class AuthWorkspaceContractTests: XCTestCase {
    // MARK: - Native sessions

    func testNativeRevokeIsABareAcknowledgement() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-native-revoke.json",
            as: SuccessResponse.self
        )
        XCTAssertTrue(response.success)
    }

    /// ⛔ `revoked` IS A COUNT, AND ZERO IS A SUCCESS. Pinned as a count rather
    /// than a boolean because the per-device route answers `revoked:0` for an id
    /// that is not yours — deliberately, so it cannot be used as an oracle over
    /// the id space — and a client that rendered that as a failure would be
    /// wrong on the most common race.
    func testRevokeResponsesCarryACount() throws {
        let all = try StrictDecodeVerifier.verify(
            fixture: "district-revoke-all.json",
            as: DeviceRevokeResponse.self
        )
        XCTAssertTrue(all.success)
        XCTAssertEqual(all.revoked, 2)

        let single = try StrictDecodeVerifier.verify(
            fixture: "district-device-revoke.json",
            as: DeviceRevokeResponse.self
        )
        XCTAssertEqual(single.revoked, 1)
    }

    /// ⛔ THE FIXTURE'S TWO ROWS ARE TWO DIFFERENT SHAPES AND THAT IS WHY IT HAS
    /// TWO. Row 0 is a fully populated install; row 1 nulls `deviceName` and
    /// `lastUsedAt` together, which is the install that signed in and has not yet
    /// rotated a refresh token — every session's first ten minutes, and the row a
    /// user is most likely to be looking at when they open this screen. A
    /// regeneration that dropped row 1 would leave both Optionals unexercised and
    /// the strict gate would not notice, because it compares shapes and not
    /// values. This test is what notices.
    func testTheDeviceListCoversBothTheNamedAndTheNeverRefreshedRow() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-devices.json",
            as: DevicesResponse.self
        )
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.devices.count, 2)

        let named = try XCTUnwrap(response.devices.first)
        XCTAssertEqual(named.deviceName, "Google Pixel 9")
        XCTAssertEqual(named.platform, "android")
        XCTAssertNotNil(named.lastUsedAt)

        let fresh = response.devices[1]
        XCTAssertNil(fresh.deviceName, "an install that sent no name")
        // ⛔ NULL, NOT ABSENT AND NOT AN EMPTY STRING. A client that rendered this
        // as a blank line would show nothing where "Signed in recently" belongs.
        XCTAssertNil(fresh.lastUsedAt, "an install that has never rotated")
        XCTAssertEqual(fresh.platform, "ios")
        XCTAssertFalse(fresh.createdAt.isEmpty, "createdAt is non-null in the schema")

        // ⛔ THE IDS ARE DISTINCT AND ARE THE ONLY THING A SCREEN MAY IDENTIFY A
        // ROW BY. Names are client-supplied free text and two identical handsets
        // produce two identical rows; marking "this device" by anything but the
        // opaque installation id is a coin flip on exactly the account where
        // getting it wrong signs out the phone in the user's hand.
        XCTAssertEqual(Set(response.devices.map(\.deviceId)).count, 2)
    }

    // MARK: - Workspace list, degraded

    /// ⛔ "WE COULD NOT LOOK" IS NOT "THERE IS NOTHING". The route answers 503
    /// with this body rather than an empty 200 precisely so the two are
    /// distinguishable, and confusing them reads to the user as account loss.
    func testDegradedWorkspaceListNamesTheRegionsItCouldNotReach() throws {
        let degraded = try StrictDecodeVerifier.verify(
            fixture: "district-workspace-list-degraded.json",
            as: WorkspaceListDegradedError.self
        )
        XCTAssertEqual(degraded.code, ApiErrorCode.regionsDegraded)
        XCTAssertEqual(degraded.degradedRegions, ["eu", "apac"])
        XCTAssertFalse(degraded.error.isEmpty)
    }

    // MARK: - Membership

    /// ⛔ ALL THREE ROLES MUST BE PRESENT IN THE FIXTURE. `role` is a plain
    /// string column server-side with no enum and no TypeScript union, and
    /// `WorkspaceRole.fromWire` fails closed on anything else — a fixture
    /// covering only `client` would never exercise that mapping, and a viewer
    /// being silently granted mutation controls is the failure it prevents.
    func testMemberListCoversEveryRoleAndIsOldestFirst() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-members.json",
            as: MemberListResponse.self
        )
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.members.count, 3)

        let roles = Set(response.members.compactMap(\.parsedRole))
        XCTAssertEqual(roles, [.agency, .client, .viewer])
        XCTAssertTrue(
            response.members.allSatisfy { $0.parsedRole != nil },
            "every role in the fixture must be one this client understands"
        )

        // ⚠️ `createdAt asc`, the opposite of every other list on this surface.
        let timestamps = response.members.map(\.createdAt)
        XCTAssertEqual(timestamps, timestamps.sorted(), "the roster is oldest-first")
    }

    /// ⛔ THE FIXTURE THAT FORCES `member` TO BE OPTIONAL. `DELETE` answers a
    /// bare `{success:true}`; a type that required the row would throw on the
    /// response to a successful REMOVAL and present a deleted member as still
    /// there.
    func testMembershipWritesShareOneTypeAcrossTwoKeySets() throws {
        let added = try StrictDecodeVerifier.verify(
            fixture: "district-member-add.json",
            as: MemberMutationResponse.self
        )
        XCTAssertEqual(added.member?.email, "newcomer@contract.test")
        XCTAssertEqual(added.member?.parsedRole, .viewer)

        let patched = try StrictDecodeVerifier.verify(
            fixture: "district-member-role-patch.json",
            as: MemberMutationResponse.self
        )
        XCTAssertEqual(patched.member?.parsedRole, .client)

        let removed = try StrictDecodeVerifier.verify(
            fixture: "district-member-remove.json",
            as: MemberMutationResponse.self
        )
        XCTAssertTrue(removed.success)
        XCTAssertNil(removed.member, "DELETE echoes no row at all")
    }

    /// The two machine-readable codes this surface branches on. Both are 409s
    /// and neither is a validation failure — nothing the operator typed is
    /// wrong — so the copy has to differ from a 400's.
    func testMembershipRefusalsCarryTheirCodes() throws {
        let duplicate = try StrictDecodeVerifier.verify(
            fixture: "district-member-duplicate.json",
            as: ApiErrorEnvelope.self
        )
        XCTAssertEqual(duplicate.success, false)
        XCTAssertEqual(duplicate.code, ApiErrorCode.memberExists)

        let lastAgency = try StrictDecodeVerifier.verify(
            fixture: "district-member-last-agency.json",
            as: ApiErrorEnvelope.self
        )
        XCTAssertEqual(lastAgency.code, ApiErrorCode.lastAgencyMember)
    }

    /// ⛔ THE ECHOED NAME IS THE TRIMMED VALUE THE SERVER STORED, and adopting it
    /// is what makes a second read unnecessary.
    func testRenameEchoesTheStoredName() throws {
        let renamed = try StrictDecodeVerifier.verify(
            fixture: "district-rename.json",
            as: RenameResponse.self
        )
        XCTAssertTrue(renamed.success)
        XCTAssertEqual(renamed.name, "Renamed Workspace")
        XCTAssertLessThanOrEqual(renamed.name.count, WorkspaceMembership.maxWorkspaceNameLength)
    }

    // MARK: - Room tokens

    /// ⛔ BOTH BRANCHES OF THE VIEWER SPLIT, AND THE VIEWER ONE IS THE SECURITY
    /// ASSERTION. The guest keys are ABSENT for a read-only seat — not null —
    /// because an invite is a transferable, publish-capable twelve-hour
    /// capability. A DTO proven against only the non-viewer fixture is proven
    /// against half the responses this route produces.
    func testRoomTokenCoversBothTheGuestAndViewerBranches() throws {
        let full = try StrictDecodeVerifier.verify(
            fixture: "district-room-token.json",
            as: RoomTokenResponse.self
        )
        XCTAssertFalse(full.token.isEmpty)
        XCTAssertTrue(full.url.hasPrefix("wss://"), "the media node URL is used verbatim")
        XCTAssertNotNil(full.guestPath)
        // ⚠️ SECONDS here, not milliseconds.
        XCTAssertNotNil(full.guestInvite)
        XCTAssertLessThan(full.guestInvite?.exp ?? .max, 100_000_000_000)
        XCTAssertFalse(full.guestInvite?.sig.isEmpty ?? true)

        let viewer = try StrictDecodeVerifier.verify(
            fixture: "district-room-token-viewer.json",
            as: RoomTokenResponse.self
        )
        XCTAssertNil(viewer.guestInvite, "a viewer must not be minted an invite")
        XCTAssertNil(viewer.guestPath)
        XCTAssertEqual(viewer.url, full.url)

        // ⛔ THE ROOM KEY, AND THE CROSS-PLATFORM CONTRACT IT CARRIES. Every LiveKit SDK
        // treats this string as a PASSPHRASE: it UTF-8-encodes the 44 ASCII characters and
        // derives the AES-GCM key with PBKDF2. A client that base64-decoded it to 32 raw
        // bytes would select HKDF instead and derive a DIFFERENT key from the same input —
        // it would join, publish, and be unable to decrypt anyone. No exception, no log,
        // just a meeting where nobody can hear each other.
        XCTAssertNotNil(full.e2ee, "a meet_ room is end-to-end encrypted")
        let key = try XCTUnwrap(full.e2ee?.key)
        XCTAssertEqual(key.count, 44, "the base64 TEXT of 32 bytes, not the bytes")
        XCTAssertTrue(key.hasSuffix("="), "base64 of 32 bytes is padded")

        // ⛔ VERBATIM, PROVEN AGAINST THE FIXTURE'S OWN BYTES rather than against a
        // hardcoded literal. The key is derived from a server-side secret, so pinning its
        // value here would couple this suite to the server's test environment and break on
        // a secret rotation that broke nothing. Asserting that the decoded string appears
        // unaltered in the source text proves the only thing that matters: the decode path
        // transforms nothing.
        let bytes = try ContractFixtures.read("district-room-token.json")
        let raw = try XCTUnwrap(String(bytes: bytes, encoding: .utf8))
        XCTAssertTrue(raw.contains(key), "the decoded key must appear verbatim in the fixture")

        // ⛔ ENCRYPTION IS A PROPERTY OF THE ROOM, NOT OF THE SEAT — the one place this
        // differs from the guest keys above. A viewer is refused an invite because an
        // invite is a transferable publish capability; it is NOT refused the room key,
        // because without it a read-only attendee could not decode the media it is
        // entitled to watch. If these two ever diverge, viewers have gone deaf and blind.
        XCTAssertEqual(viewer.e2ee?.key, key, "a viewer joins the same encrypted room")
    }

    // MARK: - The room's encryption key

    /// ⛔ THE `call_` BRANCH, WHICH HAS NO FIXTURE AND IS MOST OF THIS ROUTE'S TRAFFIC. A
    /// supervisor joining a live phone call gets no key, because the call has a SIP leg
    /// and the carrier delivers it unencrypted — there is nothing an app-side key could
    /// protect. A DTO that required the block would refuse exactly the rooms that work.
    ///
    /// ⚠️ It also proves the strict gate stays satisfied when the key is absent: a nil
    /// Optional is omitted by the synthesized encoder rather than written as `null`, so
    /// the re-encoded key set still matches the raw one. That is the same mechanism
    /// `guestInvite`/`guestPath` already rely on for the viewer fixture.
    func testRoomTokenWithoutE2EEDecodesAsAnUnencryptedJoin() throws {
        let body = Data(#"{"success":true,"token":"jwt","url":"wss://livekit.test"}"#.utf8)

        let response = try StrictDecodeVerifier.verify(
            name: "district-room-token.json/no-e2ee-literal",
            json: body,
            as: RoomTokenResponse.self
        )

        XCTAssertNil(response.e2ee, "an absent e2ee block is a valid, unencrypted join")
        XCTAssertNil(response.guestInvite)
    }

    // MARK: - Bare acknowledgements and the unread badge

    func testBareAcknowledgementsShareOneType() throws {
        for name in ["district-clear-intel.json", "district-knowledge-delete.json"] {
            let response = try StrictDecodeVerifier.verify(fixture: name, as: SuccessResponse.self)
            XCTAssertTrue(response.success, name)
        }
    }

    /// ⚠️ THE ECHOED `workspaceId` IS WHAT STOPS A STALE BADGE. The count is
    /// polled while the picker can change underneath it.
    func testUnreadCountEchoesItsWorkspace() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-messages-unread-count.json",
            as: UnreadCountResponse.self
        )
        XCTAssertEqual(response.count, 3)
        XCTAssertEqual(response.workspaceId, "ws-contract-test")
    }
}

/// The role parser, which every membership screen's affordances hang off.
final class WorkspaceRoleTests: XCTestCase {
    func testEveryWireSpellingParses() {
        XCTAssertEqual(WorkspaceRole.fromWire("agency"), .agency)
        XCTAssertEqual(WorkspaceRole.fromWire("client"), .client)
        XCTAssertEqual(WorkspaceRole.fromWire("viewer"), .viewer)
    }

    /// ⚠️ CASE-INSENSITIVE AND TRIMMED ON PURPOSE. This surface only ever writes
    /// lowercase, but a server-side whole-set replace stores whatever it
    /// was handed, and the server's own agency count is case-insensitive because
    /// of it. An "Agency" row really does grant agency.
    func testParsingIsCaseInsensitiveAndTrimmed() {
        XCTAssertEqual(WorkspaceRole.fromWire("  AGENCY "), .agency)
        XCTAssertEqual(WorkspaceRole.fromWire("Viewer"), .viewer)
    }

    /// ⛔ FAILS CLOSED. nil means "the role could not be established", which is
    /// the opposite of the server's own `client` fallback — the server reaches
    /// that conclusion having confirmed the membership exists.
    func testUnknownAndAbsentRolesFailClosed() {
        XCTAssertNil(WorkspaceRole.fromWire("superuser"))
        XCTAssertNil(WorkspaceRole.fromWire(""))
        XCTAssertNil(WorkspaceRole.fromWire(nil))
        XCTAssertFalse(WorkspaceRole.allowsMutation(nil))
        XCTAssertFalse(WorkspaceRole.allowsMutation(.viewer))
        XCTAssertTrue(WorkspaceRole.allowsMutation(.agency))
        XCTAssertTrue(WorkspaceRole.allowsMutation(.client))
    }

    func testCanMutateMirrorsTheServersAllowList() {
        XCTAssertTrue(WorkspaceRole.agency.canMutate)
        XCTAssertTrue(WorkspaceRole.client.canMutate)
        XCTAssertFalse(WorkspaceRole.viewer.canMutate)
    }

    /// ⛔ LOWERCASE ON THE WIRE. The routes normalise with `trim().toLowerCase()`
    /// and answer 400 for anything outside `agency|client|viewer`, so sending
    /// `AGENCY` is a 400 rather than a coerced value.
    func testWireValueIsLowercase() {
        XCTAssertEqual(WorkspaceRole.agency.wireValue, "agency")
        XCTAssertEqual(WorkspaceRole.viewer.wireValue, "viewer")
    }

    /// ⚠️ `client`, NOT `viewer`. The cautious guess is wrong: an operator who
    /// adds someone without touching the picker grants more than read-only.
    func testDefaultRoleAndPickerOrder() {
        XCTAssertEqual(WorkspaceMembership.defaultRole, .client)
        XCTAssertEqual(WorkspaceMembership.assignableRoles, [.agency, .client, .viewer])
        XCTAssertEqual(WorkspaceMembership.maxWorkspaceNameLength, 120)
    }
}
