import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The typed `users.*` and `teams.*` wrappers.
///
/// ⛔ THREE ENVELOPE CONVENTIONS IN ELEVEN OPS, AND THE UNWRAPPING IS WHAT THESE
/// TESTS PIN. `users.list` answers a BARE ARRAY, `users.upcomingBookings` and
/// `teams.list` answer `{items:[…]}`, and the rest answer a team or a bare `{ok}`.
/// Naming the wrong one is a runtime decode failure rather than a compile error,
/// which is the cost of not duplicating 75 schemas in Swift.
///
/// ⚠️ `userId` IS CAMELCASE ON THE WIRE FOR THE TWO MEMBER OPS while the add's is
/// `user_id`. That is the catalog's own spelling for a path key and it is not ours
/// to normalise; both are asserted below because the difference is one character
/// and invisible to every gate.
final class SchedulingAdminTeamRepositoryTests: XCTestCase {
    private func repository(_ transport: RepositoryTransport) -> SchedulingAdminRepository {
        SchedulingAdminRepository(client: .repositoryTest(transport), reportUnknownOp: { _ in })
    }

    private static let userRow = #"""
    {"id":"u_1","email":"a@test","name":"Contract Member","is_admin":true,"is_owner":true,
     "role":"owner","archived":false,"teams":[{"id":"t_1","name":"Sales"}]}
    """#

    private static let teamRow = #"""
    {"id":"t_2","name":"Support","slug":"support","member_count":0,"members":null}
    """#

    // MARK: - Scheduler users

    /// ⛔ THE `data` IS THE ARRAY ITSELF. There is no container to unwrap, which is
    /// why the response type is `[SchedulingUser]` — and why a `SchedulingItems`
    /// here would fail at runtime with a missing-key error that reads like an
    /// outage.
    func testTheUserListDecodesABareArray() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":[\#(Self.userRow)]}"#)
        let users = try await repository(transport).schedulerUsers(workspaceId: "ws_1")
        XCTAssertEqual(users.count, 1)
        XCTAssertEqual(users[0].id, "u_1")
        XCTAssertEqual(users[0].teams?.count, 1)
        XCTAssertEqual(transport.bodies, [#"{"op":"users.list","params":{},"workspaceId":"ws_1"}"#])
    }

    /// ⚠️ OMITTED WHEN `false` RATHER THAN SENT, so the default is the server's and
    /// not a value this client asserted.
    func testIncludingArchivedUsersSendsTheFlagAndOmittingItSendsNothing() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":[]}"#)
        _ = try await repository(transport).schedulerUsers(workspaceId: "ws_1", includeArchived: true)
        XCTAssertEqual(
            transport.bodies,
            [#"{"op":"users.list","params":{"include_archived":true},"workspaceId":"ws_1"}"#]
        )
    }

    func testArchivingAUserAnswersItsTimestamp() async throws {
        let transport = RepositoryTransport(
            json: #"{"ok":true,"data":{"ok":true,"archived_at":"2026-09-05T12:00:00Z"}}"#
        )
        let archived = try await repository(transport).archiveSchedulerUser(workspaceId: "ws_1", userId: "u_2")
        XCTAssertTrue(archived.ok)
        XCTAssertEqual(archived.archivedAt, "2026-09-05T12:00:00Z")
        XCTAssertEqual(transport.bodies, [#"{"op":"users.archive","params":{"id":"u_2"},"workspaceId":"ws_1"}"#])
    }

    /// ⛔ THE READ THAT MAKES THE ARCHIVE'S 409 ACTIONABLE. The fork refuses to
    /// archive a host who still owns upcoming bookings, so this is step one of a
    /// two-step the fork itself designed.
    func testUpcomingBookingsUnwrapTheItemsContainer() async throws {
        let transport = RepositoryTransport(
            json: #"""
            {"ok":true,"data":{"items":[{"id":"bk_3","start_at":"2026-09-18T15:00:00Z",
             "end_at":"2026-09-18T15:30:00Z","event_type_name":"Site visit",
             "event_type_slug":"site-visit","attendee_name":"Dana Booker",
             "attendee_email":"dana@test"}]}}
            """#
        )
        let bookings = try await repository(transport).upcomingBookings(workspaceId: "ws_1", userId: "u_2")
        XCTAssertEqual(bookings.count, 1)
        XCTAssertEqual(bookings[0].eventTypeName, "Site visit")
        XCTAssertEqual(bookings[0].attendeeEmail, "dana@test")
        XCTAssertEqual(
            transport.bodies,
            [#"{"op":"users.upcomingBookings","params":{"id":"u_2"},"workspaceId":"ws_1"}"#]
        )
    }

    // MARK: - Teams

    func testTheTeamListUnwrapsItemsAndCarriesANullMembersArray() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"items":[\#(Self.teamRow)]}}"#)
        let teams = try await repository(transport).teams(workspaceId: "ws_1")
        XCTAssertEqual(teams.count, 1)
        // ⛔ NULL, NOT `[]`, ON AN EMPTY TEAM — and `member_count` is the field that
        // agrees with it.
        XCTAssertNil(teams[0].members)
        XCTAssertEqual(teams[0].memberCount, 0)
        XCTAssertEqual(transport.bodies, [#"{"op":"teams.list","params":{},"workspaceId":"ws_1"}"#])
    }

    func testReadingOneTeamSendsItsIdAndDecodesTheRowDirectly() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.teamRow)}"#)
        let team = try await repository(transport).team(workspaceId: "ws_1", teamId: "t_2")
        XCTAssertEqual(team.id, "t_2")
        XCTAssertEqual(team.slug, "support")
        XCTAssertEqual(transport.bodies, [#"{"op":"teams.get","params":{"id":"t_2"},"workspaceId":"ws_1"}"#])
    }

    /// ⚠️ THE SLUG IS OMITTED WHEN NOT GIVEN, so the fork derives one from the name
    /// rather than being handed a guess it was about to compute correctly.
    func testCreatingATeamWithoutASlugSendsOnlyTheName() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.teamRow)}"#)
        _ = try await repository(transport).createTeam(workspaceId: "ws_1", name: "Support")
        XCTAssertEqual(
            transport.bodies,
            [#"{"op":"teams.create","params":{"name":"Support"},"workspaceId":"ws_1"}"#]
        )
    }

    func testCreatingATeamWithASlugSendsBoth() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.teamRow)}"#)
        let team = try await repository(transport).createTeam(
            workspaceId: "ws_1",
            name: "Support",
            slug: "support"
        )
        XCTAssertEqual(team.name, "Support")
        XCTAssertEqual(
            transport.bodies,
            [#"{"op":"teams.create","params":{"name":"Support","slug":"support"},"workspaceId":"ws_1"}"#]
        )
    }

    /// ⛔ A RENAME THAT DOES NOT RE-SLUG IS THE COMMON CASE AND THE SAFE ONE: the
    /// fork routes public booking pages by slug, so moving it breaks every link
    /// already handed out. Both fields are optional precisely so this call exists.
    func testRenamingATeamSendsTheNameAloneBesideThePathKey() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.teamRow)}"#)
        _ = try await repository(transport).patchTeam(workspaceId: "ws_1", teamId: "t_2", name: "Customer Support")
        XCTAssertEqual(
            transport.bodies,
            [#"{"op":"teams.patch","params":{"id":"t_2","name":"Customer Support"},"workspaceId":"ws_1"}"#]
        )
    }

    func testReslugingATeamSendsBothFields() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.teamRow)}"#)
        _ = try await repository(transport).patchTeam(
            workspaceId: "ws_1",
            teamId: "t_2",
            name: "Customer Support",
            slug: "customer-support"
        )
        XCTAssertEqual(
            transport.bodies,
            [
                #"{"op":"teams.patch","params":{"id":"t_2","name":"Customer Support","#
                    + #""slug":"customer-support"},"workspaceId":"ws_1"}"#,
            ]
        )
    }

    /// ⚠️ A 200 `{ok:true}` RATHER THAN A 204, unlike almost every other delete in
    /// this catalog — so it decodes as ``SchedulingNoContent`` by arriving in that
    /// shape rather than by being rewritten into it.
    func testDeletingATeamAnswersABareFlag() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"ok":true}}"#)
        let answer = try await repository(transport).deleteTeam(workspaceId: "ws_1", teamId: "t_2")
        XCTAssertTrue(answer.ok)
        XCTAssertEqual(transport.bodies, [#"{"op":"teams.delete","params":{"id":"t_2"},"workspaceId":"ws_1"}"#])
    }

    // MARK: - Members

    /// ⛔ `user_id`, SNAKE_CASE, ON THE ADD. And the priority is OMITTED when not
    /// given rather than defaulted to `0`, because `0` is the front of the rotation
    /// and not an absence.
    func testAddingAMemberWithoutAPrioritySendsSnakeCaseUserIdOnly() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.teamRow)}"#)
        let team = try await repository(transport).addTeamMember(
            workspaceId: "ws_1",
            teamId: "t_2",
            userId: "u_1"
        )
        XCTAssertEqual(team.id, "t_2")
        XCTAssertEqual(
            transport.bodies,
            [#"{"op":"teams.members.add","params":{"id":"t_2","user_id":"u_1"},"workspaceId":"ws_1"}"#]
        )
    }

    func testAddingAMemberAtTheFrontOfTheRotationSendsAZeroDeliberately() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.teamRow)}"#)
        _ = try await repository(transport).addTeamMember(
            workspaceId: "ws_1",
            teamId: "t_2",
            userId: "u_1",
            routingPriority: 0
        )
        XCTAssertEqual(
            transport.bodies,
            [
                #"{"op":"teams.members.add","params":{"id":"t_2","routing_priority":0,"user_id":"u_1"},"#
                    + #""workspaceId":"ws_1"}"#,
            ]
        )
    }

    /// ⛔ `userId`, CAMELCASE, ON THE PATCH — one op away from the add's `user_id`,
    /// and both path keys stay in the body.
    func testPatchingAMembersPrioritySendsCamelCaseUserIdAndBothPathKeys() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.teamRow)}"#)
        _ = try await repository(transport).setTeamMemberPriority(
            workspaceId: "ws_1",
            teamId: "t_2",
            userId: "u_1",
            routingPriority: 5
        )
        XCTAssertEqual(
            transport.bodies,
            [
                #"{"op":"teams.members.patch","params":{"id":"t_2","routing_priority":5,"userId":"u_1"},"#
                    + #""workspaceId":"ws_1"}"#,
            ]
        )
    }

    /// ⚠️ A BARE `{ok}` RATHER THAN THE TEAM, unlike the add and the patch, so a
    /// caller holding a roster has to re-read rather than replace.
    func testRemovingAMemberAnswersABareFlagAndSendsCamelCaseUserId() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"ok":true}}"#)
        let answer = try await repository(transport).removeTeamMember(
            workspaceId: "ws_1",
            teamId: "t_2",
            userId: "u_1"
        )
        XCTAssertTrue(answer.ok)
        XCTAssertEqual(
            transport.bodies,
            [#"{"op":"teams.members.remove","params":{"id":"t_2","userId":"u_1"},"workspaceId":"ws_1"}"#]
        )
    }
}
