@testable import DistrictAI
import DistrictData
import DistrictModel
import SwiftUI
import XCTest

/// The team screen's editors: a team created or renamed, its members, and a member
/// archived, over the recorded "Sales" team and the recorded scheduler users.
final class SchedulingTeamWriteSnapshotTests: SchedulingWriteSnapshotCase {
    private static let memberId = "sched-user-contract"

    /// The recorded "Sales" team from the teams list, without ``memberId``, as `teams.get`
    /// answers after the removal (CodeRabbit #144: the default reply was a different team).
    private static func salesWithoutMember() -> FixtureTransport.Reply {
        let data = FixtureTransport.fixtureData("district-scheduling-teams")
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = (root["data"] as? [String: Any])?["items"] as? [[String: Any]],
              var sales = items.first(where: { $0["name"] as? String == "Sales" }),
              let members = sales["members"] as? [[String: Any]]
        else {
            XCTFail("the recorded teams list has no Sales team with members")
            return .json("{}")
        }
        let left = members.filter { $0["id"] as? String != memberId }
        sales["members"] = left
        sales["member_count"] = left.count
        let body = (try? JSONSerialization.data(withJSONObject: ["ok": true, "data": sales])) ?? Data()
        return FixtureTransport.Reply(status: 200, body: body)
    }

    private static let memberName = "Contract Member"

    // MARK: - Create and rename

    func testTeamCreateBlank() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingTeamEditorSheet(model: self.editor(container, team: nil), teamName: "", onClose: {})
        }
    }

    /// A name that is only a space, refused on the press: trimmed, then measured.
    func testTeamCreateNameMissing() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            let model = self.editor(container, team: nil)
            model.editName(" ")
            return SnapshotPrepared(SchedulingTeamEditorSheet(model: model, teamName: "", onClose: {})) {
                await model.submit()
            }
        }
    }

    func testTeamCreated() async throws {
        try await assertScreen(
            ["op:teams.create": .fixture("district-scheduling-team")],
            devices: [.iPhone]
        ) { container in
            let model = self.editor(container, team: nil)
            model.editName("Support")
            return SnapshotPrepared(SchedulingTeamEditorSheet(model: model, teamName: "", onClose: {})) {
                await model.submit()
            }
        }
    }

    /// Renaming the recorded team: its name in the title and the delete offered.
    func testTeamRename() async throws {
        let team = try await recordedTeam()
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingTeamEditorSheet(model: self.editor(container, team: team), teamName: team.name, onClose: {})
        }
    }

    func testTeamRenameRefused() async throws {
        let team = try await recordedTeam()
        try await assertScreen(["op:teams.patch": .refused], devices: [.iPhone], locales: [.en]) { container in
            let model = self.editor(container, team: team)
            model.editName("Sales East")
            return SnapshotPrepared(SchedulingTeamEditorSheet(model: model, teamName: team.name, onClose: {})) {
                await model.submit()
            }
        }
    }

    // MARK: - Members

    /// The recorded members; every live recorded user is already in the team.
    func testMembersRecorded() async throws {
        let team = try await recordedTeam()
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingTeamMembersSheet(model: self.members(container, team), onClose: {})
        }
    }

    func testMembersWithSomeoneToAdd() async throws {
        let team = try await recordedTeam()
        try await assertScreen(["op:users.list": Self.usersWithCandidate], devices: [.iPhone]) { container in
            let model = self.members(container, team)
            return SnapshotPrepared(SchedulingTeamMembersSheet(model: model, onClose: {})) {
                await firstReadLanded { !model.addable.isEmpty }
                model.pick("sched-user-new")
            }
        }
    }

    func testMembersDirectoryRefused() async throws {
        let team = try await recordedTeam()
        try await assertScreen(["op:users.list": .refused], devices: [.iPhone]) { container in
            SchedulingTeamMembersSheet(model: self.members(container, team), onClose: {})
        }
    }

    /// ⚠️ A TEAM WITH NO MEMBERS CARRIES `members: null`: the recorded "Support" team.
    func testMembersEmptyTeam() async throws {
        let team = try await admin().team(workspaceId: Self.workspace, teamId: "team-contract-2")
        try await assertScreen(devices: [.iPhone], locales: [.en]) { container in
            SchedulingTeamMembersSheet(model: self.members(container, team), onClose: {})
        }
    }

    /// A routing priority that is not a whole number, refused on that member's row.
    func testMembersPriorityInvalid() async throws {
        let team = try await recordedTeam()
        try await assertScreen(devices: [.iPhone], locales: [.en]) { container in
            let model = self.members(container, team)
            model.editPriority("2.5", for: Self.memberId)
            return SnapshotPrepared(SchedulingTeamMembersSheet(model: model, onClose: {})) {
                await model.savePriority(for: Self.memberId)
            }
        }
    }

    /// Removed: the re-read of the same team ("Sales" as recorded, without the member just
    /// removed) is what is drawn.
    func testMembersRemoved() async throws {
        let team = try await recordedTeam()
        try await assertScreen(
            [
                "op:teams.members.remove": .fixture("district-scheduling-ok"),
                "op:teams.get": Self.salesWithoutMember(),
            ],
            devices: [.iPhone],
            locales: [.en]
        ) { container in
            let model = self.members(container, team)
            return SnapshotPrepared(SchedulingTeamMembersSheet(model: model, onClose: {})) {
                await model.removeMember(Self.memberId)
            }
        }
    }

    // MARK: - Archiving a member

    /// ⛔ BLOCKED BY A BOOKING STILL AHEAD: the recorded upcoming one, told in the viewer's
    /// zone, and the button off with the reason under it.
    func testArchiveBlocked() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingUserArchiveSheet(model: self.archive(container), userName: Self.memberName, onClose: {})
        }
    }

    func testArchiveClear() async throws {
        try await assertScreen(["op:users.upcomingBookings": .noItems], devices: [.iPhone]) { container in
            SchedulingUserArchiveSheet(model: self.archive(container), userName: Self.memberName, onClose: {})
        }
    }

    /// ⛔ A FAILED COUNT DOES NOT UNLOCK THE BUTTON: "we could not look" is not "nothing".
    func testArchiveCountFailed() async throws {
        try await assertScreen(["op:users.upcomingBookings": .refused], devices: [.iPhone]) { container in
            SchedulingUserArchiveSheet(model: self.archive(container), userName: Self.memberName, onClose: {})
        }
    }

    func testArchived() async throws {
        try await assertScreen(
            [
                "op:users.upcomingBookings": .noItems,
                "op:users.archive": .fixture("district-scheduling-user-archive"),
            ],
            devices: [.iPhone]
        ) { container in
            let model = self.archive(container)
            return SnapshotPrepared(SchedulingUserArchiveSheet(model: model, userName: Self.memberName, onClose: {})) {
                await firstReadLanded { model.canArchive }
                await model.archive()
            }
        }
    }

    // MARK: - Models

    private func editor(_ container: AppContainer, team: SchedulingTeam?) -> SchedulingTeamEditorModel {
        SchedulingTeamEditorModel(
            admin: container.schedulingAdmin,
            workspaceId: Self.workspace,
            team: team,
            onSaved: { _ in },
            onDeleted: { _ in }
        )
    }

    private func members(_ container: AppContainer, _ team: SchedulingTeam) -> SchedulingTeamMembersModel {
        SchedulingTeamMembersModel(
            admin: container.schedulingAdmin,
            workspaceId: Self.workspace,
            team: team,
            onSaved: { _ in }
        )
    }

    private func archive(_ container: AppContainer) -> SchedulingUserArchiveModel {
        SchedulingUserArchiveModel(
            admin: container.schedulingAdmin,
            workspaceId: Self.workspace,
            userId: Self.memberId,
            userName: Self.memberName,
            timezone: "America/Toronto",
            onArchived: { _ in }
        )
    }
}
