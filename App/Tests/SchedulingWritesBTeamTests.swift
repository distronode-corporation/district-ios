@testable import DistrictAI
import DistrictData
import DistrictModel
import Foundation
import XCTest

/// Teams, rosters and offboarding.
///
/// ⛔ THE MEMBER ID IS SPELLED TWO WAYS ACROSS THREE OPS — `user_id` on the add and
/// `userId` on the patch and the remove — and that is the catalog's spelling for a
/// path key rather than an inconsistency to normalise. A snake_case `user_id` on the
/// patch is an `invalid_params`. These tests pin both spellings, because nothing
/// else in the build can.
@MainActor
final class SchedulingWritesBTeamTests: XCTestCase {
    private typealias Fixtures = SchedulingWritesBFixtures

    // MARK: - Create, rename, delete

    /// ⛔ NO `slug` KEY. The fork derives one from the name; sending a guess is a way
    /// to disagree with the server about an identifier it was about to choose
    /// correctly.
    func testCreatingATeamSendsTheTrimmedNameAndNoSlug() async {
        let transport = SettingsTransport([Fixtures.ok(Fixtures.team())])
        var saved: SchedulingTeam?
        let model = SchedulingTeamEditorModel(
            admin: Fixtures.repository(transport),
            workspaceId: Fixtures.workspaceId,
            team: nil,
            onSaved: { saved = $0 },
            onDeleted: { _ in }
        )
        model.editName("  Front desk  ")
        await model.submit()

        XCTAssertEqual(Fixtures.op(transport), "teams.create")
        XCTAssertEqual(Fixtures.params(transport)["name"] as? String, "Front desk")
        XCTAssertNil(Fixtures.params(transport)["slug"])
        XCTAssertEqual(Fixtures.done(model.state), SchedulingTeamWriteCopy.createDone)
        XCTAssertEqual(saved?.id, "t-1")
    }

    /// ⛔ A RENAME CARRIES THE NAME AND THE ID, NEVER A SLUG. Re-slugging breaks every
    /// public team booking URL already handed out, and this form has no control for
    /// it precisely so it cannot happen by accident.
    func testRenamingATeamNeverSendsASlug() async throws {
        let transport = SettingsTransport([Fixtures.ok(Fixtures.team(name: "Reception"))])
        let model = try SchedulingTeamEditorModel(
            admin: Fixtures.repository(transport),
            workspaceId: Fixtures.workspaceId,
            team: Self.team(),
            onSaved: { _ in },
            onDeleted: { _ in }
        )
        model.editName("Reception")
        await model.submit()

        XCTAssertEqual(Fixtures.op(transport), "teams.patch")
        XCTAssertEqual(Fixtures.params(transport)["id"] as? String, "t-1")
        XCTAssertEqual(Fixtures.params(transport)["name"] as? String, "Reception")
        XCTAssertNil(Fixtures.params(transport)["slug"])
    }

    /// ⚠️ TRIMMED, THEN MEASURED. A single space is what a spacebar tap produces in
    /// an empty field, and the order decides whether that counts as a name.
    func testANameOfNothingButSpacesIsRefusedBeforeAnyRequest() async {
        let transport = SettingsTransport([])
        let model = SchedulingTeamEditorModel(
            admin: Fixtures.repository(transport),
            workspaceId: Fixtures.workspaceId,
            team: nil,
            onSaved: { _ in },
            onDeleted: { _ in }
        )
        model.editName("   ")
        await model.submit()

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(model.nameRejected, SchedulingTeamWriteCopy.nameRequired)
    }

    func testANameOverTheCatalogsCeilingIsRefusedBeforeAnyRequest() async {
        let transport = SettingsTransport([])
        let model = SchedulingTeamEditorModel(
            admin: Fixtures.repository(transport),
            workspaceId: Fixtures.workspaceId,
            team: nil,
            onSaved: { _ in },
            onDeleted: { _ in }
        )
        model.editName(String(repeating: "n", count: SchedulingTeamEditorModel.nameLimit + 1))
        await model.submit()

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(model.nameRejected, SchedulingTeamWriteCopy.nameTooLong)
    }

    /// ⚠️ `teams.delete` ANSWERS A 200 `{ok:true}`, NOT A 204, unlike almost every
    /// other delete in the catalog.
    func testDeletingATeamHandsBackTheIdTheCallerHasToDrop() async throws {
        let transport = SettingsTransport([Fixtures.noContent])
        var deleted: String?
        let model = try SchedulingTeamEditorModel(
            admin: Fixtures.repository(transport),
            workspaceId: Fixtures.workspaceId,
            team: Self.team(),
            onSaved: { _ in },
            onDeleted: { deleted = $0 }
        )
        await model.delete()

        XCTAssertEqual(Fixtures.op(transport), "teams.delete")
        XCTAssertEqual(Fixtures.params(transport)["id"] as? String, "t-1")
        XCTAssertEqual(deleted, "t-1")
        XCTAssertEqual(Fixtures.done(model.state), SchedulingTeamWriteCopy.deleteDone)
    }

    // MARK: - Members

    /// ⛔ NO `routing_priority` ON THE ADD. A literal `0` is a real priority that puts
    /// the new member at the FRONT of every rotation; omitting it lets the fork
    /// choose.
    func testAddingAMemberSendsUserIdInSnakeCaseAndNoPriority() async throws {
        let transport = SettingsTransport([
            Fixtures.ok("[\(Fixtures.user(id: "u-9"))]"),
            Fixtures.ok(Fixtures.team(members: "[\(Fixtures.member(id: "u-9", priority: 3))]")),
        ])
        let model = try SchedulingTeamMembersModel(
            admin: Fixtures.repository(transport),
            workspaceId: Fixtures.workspaceId,
            team: Self.team(),
            onSaved: { _ in }
        )
        await model.loadUsers()
        model.pick("u-9")
        await model.addMember()

        XCTAssertEqual(Fixtures.op(transport, 1), "teams.members.add")
        let params = Fixtures.params(transport, 1)
        XCTAssertEqual(params["id"] as? String, "t-1")
        XCTAssertEqual(params["user_id"] as? String, "u-9")
        XCTAssertNil(params["routing_priority"])
        XCTAssertEqual(model.members.map(\.id), ["u-9"])
    }

    /// ⛔ `userId` IN CAMELCASE ON THE PATCH. See the type note.
    func testSavingAPrioritySendsUserIdInCamelCase() async throws {
        let transport = SettingsTransport([
            Fixtures.ok(Fixtures.team(members: "[\(Fixtures.member(id: "u-9", priority: 5))]")),
        ])
        let model = try SchedulingTeamMembersModel(
            admin: Fixtures.repository(transport),
            workspaceId: Fixtures.workspaceId,
            team: Self.team(members: "[\(Fixtures.member(id: "u-9", priority: 3))]"),
            onSaved: { _ in }
        )
        model.editPriority("5", for: "u-9")
        await model.savePriority(for: "u-9")

        XCTAssertEqual(Fixtures.op(transport), "teams.members.patch")
        let params = Fixtures.params(transport)
        XCTAssertEqual(params["userId"] as? String, "u-9")
        XCTAssertNil(params["user_id"])
        XCTAssertEqual(params["routing_priority"] as? Int, 5)
        // ⚠️ THE DRAFT IS RESEEDED FROM THE SERVER'S ANSWER, so a value the fork
        // normalised cannot sit behind a field still showing what was typed.
        XCTAssertEqual(model.priorityDrafts["u-9"], "5")
    }

    /// ⚠️ REFUSES A DECIMAL AND AN EMPTY FIELD RATHER THAN COERCING EITHER, which is
    /// `parsePriority`'s rule. Swift needs no separate empty check where JavaScript
    /// does, and the SENTENCE is what has to match.
    func testAPriorityThatIsNotAWholeNumberIsRefusedBeforeAnyRequest() async throws {
        for raw in ["", "2.5", "-1", "many"] {
            let transport = SettingsTransport([])
            let model = try SchedulingTeamMembersModel(
                admin: Fixtures.repository(transport),
                workspaceId: Fixtures.workspaceId,
                team: Self.team(members: "[\(Fixtures.member(id: "u-9", priority: 3))]"),
                onSaved: { _ in }
            )
            model.editPriority(raw, for: "u-9")
            await model.savePriority(for: "u-9")

            XCTAssertTrue(transport.requests.isEmpty, "\(raw) should spend no request")
            XCTAssertEqual(model.priorityRejected["u-9"], SchedulingTeamWriteCopy.priorityInvalid)
        }
    }

    /// ⛔ THE REMOVE ANSWERS A BARE `{ok}`, SO THE ROSTER IS RE-READ. A caller
    /// patching its own copy would be guessing at a rotation the fork owns.
    func testRemovingAMemberReReadsTheTeamBecauseTheOpEchoesNothing() async throws {
        let transport = SettingsTransport([
            Fixtures.noContent,
            Fixtures.ok(Fixtures.team(members: "[]")),
        ])
        let model = try SchedulingTeamMembersModel(
            admin: Fixtures.repository(transport),
            workspaceId: Fixtures.workspaceId,
            team: Self.team(members: "[\(Fixtures.member(id: "u-9", priority: 3))]"),
            onSaved: { _ in }
        )
        await model.removeMember("u-9")

        XCTAssertEqual(Fixtures.op(transport), "teams.members.remove")
        XCTAssertEqual(Fixtures.params(transport)["userId"] as? String, "u-9")
        XCTAssertEqual(Fixtures.op(transport, 1), "teams.get")
        XCTAssertTrue(model.members.isEmpty)
        XCTAssertEqual(Fixtures.done(model.state), SchedulingTeamWriteCopy.removeDone)
    }

    // MARK: - Archiving

    /// ⛔ THE BUTTON IS LOCKED UNTIL THE COUNT HAS BEEN READ AND IS ZERO. The fork
    /// refuses with a 409 while the user still hosts anything, so offering it sooner
    /// offers a refusal.
    func testArchiveIsRefusedUntilTheUpcomingBookingsHaveBeenReadAndAreEmpty() async {
        let upcoming = """
        {"items":[{"id":"bk-1","start_at":"2026-09-20T15:00:00Z","end_at":"2026-09-20T15:30:00Z",
        "event_type_name":"Intro","event_type_slug":"intro","attendee_name":"Sam",
        "attendee_email":"sam@example.com"}]}
        """
        let transport = SettingsTransport([Fixtures.ok(upcoming)])
        let model = Self.archiveModel(transport)
        XCTAssertFalse(model.canArchive)

        await model.loadUpcoming()
        XCTAssertFalse(model.canArchive)
        XCTAssertEqual(model.blockedReason, SchedulingTeamWriteCopy.archiveBlocked)

        await model.archive()
        XCTAssertEqual(transport.requests.count, 1, "the archive itself must not be sent")
    }

    /// ⛔ A FAILED READ IS NOT AN EMPTY DIARY. "We could not look" and "there is
    /// nothing" are different answers and only one of them may unlock the button.
    func testAFailedUpcomingReadLeavesTheArchiveLocked() async {
        let transport = SettingsTransport([Fixtures.refusal("unavailable")])
        let model = Self.archiveModel(transport)
        await model.loadUpcoming()

        XCTAssertFalse(model.canArchive)
        XCTAssertTrue(model.bookings.isEmpty)
    }

    func testArchiveSendsTheUserIdAndNamesThePersonInTheVerdict() async {
        let transport = SettingsTransport([
            Fixtures.ok("{\"items\":[]}"),
            Fixtures.ok("{\"ok\":true,\"archived_at\":\"2026-09-12T00:00:00Z\"}"),
        ])
        var archived: String?
        let model = SchedulingUserArchiveModel(
            admin: Fixtures.repository(transport),
            workspaceId: Fixtures.workspaceId,
            userId: "u-9",
            userName: "Grace",
            onArchived: { archived = $0 }
        )
        await model.loadUpcoming()
        XCTAssertTrue(model.canArchive)
        XCTAssertNil(model.blockedReason)
        await model.archive()

        XCTAssertEqual(Fixtures.op(transport, 1), "users.archive")
        XCTAssertEqual(Fixtures.params(transport, 1)["id"] as? String, "u-9")
        XCTAssertEqual(Fixtures.done(model.state), "Grace's scheduler account is closed")
        XCTAssertEqual(archived, "u-9")
    }

    /// ⛔ THE FORK'S FOUR 4xx REFUSALS ARE ALL COLLAPSED TO `unknown` BEFORE A SCREEN
    /// SEES THEM, so the sentence enumerates rather than asserting one cause. Naming
    /// a single reason here would be this client stating as fact something it was
    /// never told.
    func testAnArchiveRefusalEnumeratesTheCausesItCannotTellApart() {
        XCTAssertEqual(
            SchedulingUserArchiveModel.refusal(SchedulingAdminError.unknown).message,
            SchedulingTeamWriteCopy.archiveRefused
        )
        // ⛔ AND A DECODE FAILURE IS NOT AN ARCHIVE REFUSAL, though both collapse to
        // the same ui code. Telling somebody their account "may be the workspace
        // owner" when the app failed to parse a response invents a cause. This is
        // the assertion that makes the arm a `case .unknown` match rather than a
        // `uiCode == .unknown` one.
        XCTAssertEqual(
            SchedulingUserArchiveModel.refusal(SchedulingAdminError.decoding("shape")).message,
            SchedulingWritesBFailure.staleBuildMessage
        )
        // ⚠️ AND EVERY OTHER ARM KEEPS THE SHARED MAPPING, so a 5xx still reads as a
        // 5xx rather than as a statement about this account.
        XCTAssertEqual(
            SchedulingUserArchiveModel.refusal(SchedulingAdminError.unavailable).message,
            SchedulingWritesBFailure.unavailableMessage
        )
    }

    // MARK: - Fixtures

    private static func team(members: String = "null") throws -> SchedulingTeam {
        // ⚠️ DECODED RATHER THAN BUILT, because the DTO's memberwise initialiser is
        // internal to `DistrictModel` — and because decoding is what the app does.
        let json = SchedulingWritesBFixtures.team(members: members)
        return try JSONDecoder().decode(SchedulingTeam.self, from: Data(json.utf8))
    }

    private static func archiveModel(_ transport: SettingsTransport) -> SchedulingUserArchiveModel {
        SchedulingUserArchiveModel(
            admin: SchedulingWritesBFixtures.repository(transport),
            workspaceId: SchedulingWritesBFixtures.workspaceId,
            userId: "u-9",
            userName: "Grace",
            onArchived: { _ in }
        )
    }
}
