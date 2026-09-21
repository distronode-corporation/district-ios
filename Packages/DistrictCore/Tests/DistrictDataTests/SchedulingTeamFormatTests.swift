import DistrictData
import DistrictModel
import Foundation
import XCTest

/// Joining District's members to the scheduler's users.
final class SchedulingTeamFormatTests: XCTestCase {
    private typealias Team = SchedulingTeamFormat

    private func member(_ email: String, role: String? = "client") -> SchedulingDistrictMember {
        SchedulingDistrictMember(email: email, role: role)
    }

    // MARK: - nameFromEmail

    func testTheNameIsTheLocalPart() {
        XCTAssertEqual(Team.nameFromEmail("ada@example.com"), "ada")
        XCTAssertEqual(Team.nameFromEmail("  ada@example.com  "), "ada")
        XCTAssertEqual(Team.nameFromEmail("ada"), "ada", "no @ at all is the whole string")
        XCTAssertEqual(Team.nameFromEmail("ada@b@example.com"), "ada", "only the first @ splits")
    }

    /// ⚠️ AN EMPTY LOCAL PART FALLS BACK TO THE WHOLE ADDRESS, because an empty name cell
    /// reads as data that failed to load.
    func testAnEmptyLocalPartFallsBackToTheAddress() {
        XCTAssertEqual(Team.nameFromEmail("@example.com"), "@example.com")
        XCTAssertEqual(Team.nameFromEmail(""), "")
    }

    // MARK: - joinMembers

    func testAMemberWithASchedulerAccountIsAHost() throws {
        let rows = try Team.joinMembers(
            district: [member("ada@example.com")],
            scheduler: [SchedulingFixture.schedulerUser(email: "ada@example.com", name: "Ada L")]
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].state, .host)
        XCTAssertEqual(rows[0].name, "Ada L")
        XCTAssertEqual(rows[0].schedulerUserId, "u1")
        XCTAssertEqual(rows[0].districtRole, "client")
    }

    /// ⚠️ A MEMBER WITH NO SCHEDULER ACCOUNT IS `absent` AND CARRIES NO USER ID.
    func testAMemberWithNoSchedulerAccountIsAbsent() {
        let rows = Team.joinMembers(district: [member("ada@example.com")], scheduler: [])
        XCTAssertEqual(rows[0].state, .absent)
        XCTAssertNil(rows[0].schedulerUserId)
        XCTAssertEqual(rows[0].name, "ada")
    }

    /// ⛔ THE JOIN IS CASE-INSENSITIVE, because one side is whatever was typed into an
    /// invite and the other is whatever was typed into the scheduler.
    func testTheJoinIsCaseInsensitive() throws {
        let rows = try Team.joinMembers(
            district: [member("Ada@Example.COM")],
            scheduler: [SchedulingFixture.schedulerUser(email: "ada@example.com", name: "Ada")]
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].state, .host)
        XCTAssertEqual(rows[0].key, "ada@example.com")
    }

    /// ⚠️ THE DISPLAYED ADDRESS KEEPS THE SOURCE'S CASING; only the key is normalised.
    func testTheDisplayedAddressKeepsItsCasing() throws {
        let rows = try Team.joinMembers(
            district: [member("Ada@Example.COM")],
            scheduler: [SchedulingFixture.schedulerUser(email: "ada@example.com", name: "Ada")]
        )
        XCTAssertEqual(rows[0].email, "Ada@Example.COM")
    }

    /// ⛔ DISTRICT'S ORDER FIRST, THEN SCHEDULER-ONLY ROWS. The second pass is what
    /// surfaces somebody who has left, which is exactly who an operator needs to see.
    func testSchedulerOnlyRowsComeAfterAndCarryNoDistrictRole() throws {
        let rows = try Team.joinMembers(
            district: [member("ada@example.com")],
            scheduler: [
                SchedulingFixture.schedulerUser(id: "u1", email: "ada@example.com", name: "Ada"),
                SchedulingFixture.schedulerUser(id: "u2", email: "bob@example.com", name: "Bob"),
            ]
        )
        XCTAssertEqual(rows.map(\.key), ["ada@example.com", "bob@example.com"])
        XCTAssertEqual(rows[1].districtRole, nil)
        XCTAssertEqual(rows[1].state, .host)
    }

    func testAnArchivedSchedulerAccountIsArchived() throws {
        let rows = try Team.joinMembers(
            district: [member("ada@example.com")],
            scheduler: [
                SchedulingFixture.schedulerUser(email: "ada@example.com", name: "Ada", archived: true),
            ]
        )
        XCTAssertEqual(rows[0].state, .archived)
    }

    /// ⚠️ A DUPLICATE ADDRESS IS SKIPPED AFTER THE FIRST.
    func testADuplicateDistrictAddressProducesOneRow() {
        let rows = Team.joinMembers(
            district: [member("ada@example.com"), member("ADA@example.com", role: "agency")],
            scheduler: []
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].districtRole, "client")
    }

    /// ⚠️ THE SCHEDULER-SIDE LOOKUP KEEPS THE **LAST** USER FOR A DUPLICATED ADDRESS,
    /// which is the source's `Map.set` behaviour and a fork-side anomaly this screen
    /// reports rather than resolves.
    func testTheLastSchedulerUserWinsForADuplicatedAddress() throws {
        let rows = try Team.joinMembers(
            district: [member("ada@example.com")],
            scheduler: [
                SchedulingFixture.schedulerUser(id: "u1", email: "ada@example.com", name: "First"),
                SchedulingFixture.schedulerUser(id: "u2", email: "ada@example.com", name: "Second"),
            ]
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].schedulerUserId, "u2")
        XCTAssertEqual(rows[0].name, "Second")
    }

    /// ⚠️ A WHITESPACE SCHEDULER NAME FALLS BACK TO THE ADDRESS'S LOCAL PART. This is the
    /// JavaScript `||` and the reason a `??` port would render a blank cell.
    func testAWhitespaceSchedulerNameFallsBackToTheLocalPart() throws {
        let rows = try Team.joinMembers(
            district: [member("ada@example.com")],
            scheduler: [SchedulingFixture.schedulerUser(email: "ada@example.com", name: "   ")]
        )
        XCTAssertEqual(rows[0].name, "ada")
    }

    func testNobodyAtAllIsAnEmptyList() {
        XCTAssertTrue(Team.joinMembers(district: [], scheduler: []).isEmpty)
    }

    // MARK: - Labels

    func testTheThreeStatesGetTheirOwnWording() {
        XCTAssertEqual(Team.memberStateLabel(.host), SchedulingStatusLabel(label: "Host", kind: .success))
        XCTAssertEqual(
            Team.memberStateLabel(.archived),
            SchedulingStatusLabel(label: "Archived", kind: .stopped)
        )
        XCTAssertEqual(
            Team.memberStateLabel(.absent),
            SchedulingStatusLabel(label: "Not set up yet", kind: .info)
        )
    }

    func testTheDistrictRolesAreLabelled() {
        XCTAssertEqual(Team.districtRoleLabel("agency"), "Agency")
        XCTAssertEqual(Team.districtRoleLabel("client"), "Client")
        XCTAssertEqual(Team.districtRoleLabel("viewer"), "Viewer")
        XCTAssertEqual(Team.districtRoleLabel(" AGENCY "), "Agency")
    }

    /// ⛔ nil IS A SENTENCE, NOT A BLANK: it is somebody who has left the workspace.
    func testNoDistrictRoleSaysSo() {
        XCTAssertEqual(Team.districtRoleLabel(nil), "Removed from the workspace")
    }

    /// ⚠️ AN UNKNOWN ROLE IS ECHOED **AS IT CAME**, not as the normalised form, because
    /// that is the value an operator would have to quote in a support request.
    func testAnUnknownRoleKeepsItsOriginalCasing() {
        XCTAssertEqual(Team.districtRoleLabel("SuperUser"), "SuperUser")
    }

    // MARK: - Stranded hosts

    private func rows() throws -> [SchedulingMemberRow] {
        try Team.joinMembers(
            district: [member("ada@example.com")],
            scheduler: [
                SchedulingFixture.schedulerUser(id: "u1", email: "ada@example.com", name: "Ada"),
                SchedulingFixture.schedulerUser(id: "u2", email: "bob@example.com", name: "Bob"),
                SchedulingFixture.schedulerUser(id: "u3", email: "cy@example.com", name: "Cy"),
            ]
        )
    }

    func testStrandedHostsAreThoseWithNoDistrictRowAndALiveAccount() throws {
        XCTAssertEqual(try Team.strandedHosts(rows()).map(\.name), ["Bob", "Cy"])
    }

    /// ⚠️ AN ARCHIVED ACCOUNT IS NOT STRANDED — it is already dealt with.
    func testAnArchivedAccountIsNotStranded() throws {
        let rows = try Team.joinMembers(
            district: [],
            scheduler: [
                SchedulingFixture.schedulerUser(email: "bob@example.com", name: "Bob", archived: true),
            ]
        )
        XCTAssertTrue(Team.strandedHosts(rows).isEmpty)
    }

    /// ⛔ FOUR CLAUSES MOVE WITH THE COUNT: `is`/`are`, `holds`/`hold`, `account` twice.
    func testTheStrandedNoticeIsSingularForOne() throws {
        let one = try Array(Team.strandedHosts(rows()).prefix(1))
        let notice = Team.strandedNotice(one)
        XCTAssertTrue(notice.hasPrefix("Bob is no longer"))
        XCTAssertTrue(notice.contains("still holds upcoming bookings"))
        XCTAssertTrue(notice.contains("kept their account open"))
        XCTAssertTrue(notice.hasSuffix("then archive the account."))
    }

    func testTheStrandedNoticeIsPluralForMoreThanOne() throws {
        let notice = try Team.strandedNotice(Team.strandedHosts(rows()))
        XCTAssertTrue(notice.hasPrefix("Bob and Cy are no longer"))
        XCTAssertTrue(notice.contains("still hold upcoming bookings"))
        XCTAssertTrue(notice.contains("kept their accounts open"))
        XCTAssertTrue(notice.hasSuffix("then archive the accounts."))
    }

    /// ⚠️ NO OXFORD COMMA: three names read "A, B and C".
    func testThreeNamesUseCommasThenAndWithNoOxfordComma() throws {
        let rows = try Team.joinMembers(
            district: [],
            scheduler: [
                SchedulingFixture.schedulerUser(id: "u1", email: "a@e.com", name: "Ada"),
                SchedulingFixture.schedulerUser(id: "u2", email: "b@e.com", name: "Bob"),
                SchedulingFixture.schedulerUser(id: "u3", email: "c@e.com", name: "Cy"),
            ]
        )
        XCTAssertTrue(Team.strandedNotice(rows).hasPrefix("Ada, Bob and Cy are"))
    }

    func testNobodyStrandedIsAnEmptyNotice() {
        XCTAssertEqual(Team.strandedNotice([]), "")
    }

    // MARK: - needsBookingResolution

    func testResolutionIsNeededForSomebodyGoneOrArchived() throws {
        let rows = try rows()
        let ada = try XCTUnwrap(rows.first { $0.name == "Ada" })
        XCTAssertFalse(Team.needsBookingResolution(ada))

        let bob = try XCTUnwrap(rows.first { $0.name == "Bob" })
        XCTAssertTrue(Team.needsBookingResolution(bob))
    }

    /// ⚠️ SOMEBODY WITH NO SCHEDULER ACCOUNT HAS NOTHING TO RESOLVE.
    func testAnAbsentAccountNeedsNoResolution() {
        let rows = Team.joinMembers(district: [member("ada@example.com", role: nil)], scheduler: [])
        XCTAssertFalse(Team.needsBookingResolution(rows[0]))
    }

    // MARK: - teamMemberCount

    /// ⚠️ A SERVER-REPORTED ZERO IS HONOURED rather than falling through to the inlined
    /// array's length. That is `??` and not `||`.
    func testAReportedZeroIsHonoured() throws {
        let team = try SchedulingFixture.team(
            memberCount: 0,
            members: #"[{"id":"m1","name":"A","email":"a@e","routing_priority":0,"archived":false}]"#
        )
        XCTAssertEqual(Team.teamMemberCount(team), 0)
    }

    func testTheCountFallsBackToTheInlinedMembersThenToZero() throws {
        let inlined = try SchedulingFixture
            .team(members: #"[{"id":"m1","name":"A","email":"a@e","routing_priority":0,"archived":false}]"#)
        XCTAssertEqual(Team.teamMemberCount(inlined), 1)

        let bare = try SchedulingFixture.team()
        XCTAssertEqual(Team.teamMemberCount(bare), 0)
    }

    // MARK: - archiveRefusalSentence

    /// ⚠️ CHOSEN FROM THE HTTP STATUS RATHER THAN FROM ANY TEXT THE FORK SENDS, because
    /// the fork's own wording never travels.
    func testEachRefusalStatusGetsItsOwnSentence() {
        XCTAssertTrue(Team.archiveRefusalSentence(status: 409, fallback: "x").hasPrefix("They still have"))
        XCTAssertTrue(Team.archiveRefusalSentence(status: 403, fallback: "x").hasPrefix("You cannot archive"))
        XCTAssertTrue(Team.archiveRefusalSentence(status: 400, fallback: "x").hasPrefix("That account cannot"))
        XCTAssertEqual(
            Team.archiveRefusalSentence(status: 404, fallback: "x"),
            "The booking system no longer has that account."
        )
        XCTAssertEqual(Team.archiveRefusalSentence(status: 500, fallback: "x"), "x")
    }
}
