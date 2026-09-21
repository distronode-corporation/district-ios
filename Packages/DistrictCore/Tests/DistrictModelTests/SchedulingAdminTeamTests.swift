import DistrictModel
import Foundation
import XCTest

/// The `users.*` and `teams.*` row DTOs, decoded from inline bytes.
///
/// ⛔ THE TWO NULLABLE ARRAYS ON THIS SURFACE ARE PROVED IN BOTH POLARITIES HERE.
/// `SchedulingUser.teams` and `SchedulingTeam.members` are `.nullish()` — Go
/// slices the fork marshals without `omitempty` — so each has to decode from an
/// explicit `null`, from an absent key AND from a populated array. The committed
/// fixtures demonstrate the null (which is why all three have
/// `allowedExplicitNulls` entries); the other two polarities have no fixture and
/// live here.
final class SchedulingAdminTeamTests: XCTestCase {
    private let decoder = JSONDecoder()

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }

    // MARK: - Scheduler users

    func testAnActiveUserCarriesItsTeamsAndNoArchiveColumns() throws {
        let user = try decode(
            SchedulingUser.self,
            #"""
            {"id":"u_1","email":"a@test","name":"Contract Member","timezone":"America/Toronto",
             "is_admin":true,"is_owner":true,"role":"owner","email_login":false,"provider":"oidc",
             "avatar_url":"https://example.test/a.png","created_at":"2026-09-01T09:00:00Z",
             "archived":false,"teams":[{"id":"t_1","name":"Sales"}]}
            """#
        )
        XCTAssertEqual(user.id, "u_1")
        XCTAssertEqual(user.email, "a@test")
        XCTAssertEqual(user.name, "Contract Member")
        XCTAssertEqual(user.timezone, "America/Toronto")
        XCTAssertTrue(user.isAdmin)
        XCTAssertTrue(user.isOwner)
        XCTAssertEqual(user.role, "owner")
        XCTAssertEqual(user.emailLogin, false)
        XCTAssertEqual(user.provider, "oidc")
        XCTAssertEqual(user.avatarUrl, "https://example.test/a.png")
        XCTAssertEqual(user.createdAt, "2026-09-01T09:00:00Z")
        XCTAssertFalse(user.archived)
        // ⛔ ABSENT, NOT NULL, on an active user. The Optionals mean "not archived"
        // and must not be read as "we do not know who archived them".
        XCTAssertNil(user.archivedAt)
        XCTAssertNil(user.archivedByName)
        XCTAssertEqual(user.teams?.count, 1)
        XCTAssertEqual(user.teams?[0].id, "t_1")
        XCTAssertEqual(user.teams?[0].name, "Sales")
    }

    /// ⛔ `teams: null` IS THE WIRE SHAPE FOR A USER IN NO TEAM, not an absent key.
    /// This is the row that earns `$.data[1].teams` its allowlist entry.
    func testAUserInNoTeamDecodesAnExplicitNull() throws {
        let user = try decode(
            SchedulingUser.self,
            #"""
            {"id":"u_2","email":"gone@test","name":"Former Host","is_admin":false,
             "is_owner":false,"role":"member","archived":true,
             "archived_at":"2026-09-05T12:00:00Z","archived_by_name":"Contract Member",
             "teams":null}
            """#
        )
        XCTAssertNil(user.teams)
        XCTAssertTrue(user.archived)
        XCTAssertEqual(user.archivedAt, "2026-09-05T12:00:00Z")
        XCTAssertEqual(user.archivedByName, "Contract Member")
        // ⚠️ THE SPARSE HALF OF THE SAME ROW: an archived user carries no timezone,
        // no provider, no avatar and no `created_at`, all as ABSENT keys.
        XCTAssertNil(user.timezone)
        XCTAssertNil(user.emailLogin)
        XCTAssertNil(user.provider)
        XCTAssertNil(user.avatarUrl)
        XCTAssertNil(user.createdAt)
    }

    /// ⚠️ `.nullish()` PERMITS AN ABSENT KEY TOO, and no fixture carries that
    /// polarity — a DTO that handled only the null would throw on it.
    func testAUserWithNoTeamsKeyAtAllStillDecodes() throws {
        let user = try decode(
            SchedulingUser.self,
            #"""
            {"id":"u_3","email":"c@test","name":"Third","is_admin":false,"is_owner":false,
             "role":"member","archived":false}
            """#
        )
        XCTAssertNil(user.teams)
    }

    /// ⛔ `archived` IS REQUIRED AND MUST NOT DEFAULT. A missing flag would make
    /// every user read as active, including the ones who cannot sign in.
    func testAUserWithoutTheArchivedFlagIsRefused() {
        XCTAssertThrowsError(
            try decode(
                SchedulingUser.self,
                #"{"id":"u_4","email":"d@test","name":"Fourth","is_admin":false,"is_owner":false,"role":"member"}"#
            )
        )
    }

    // MARK: - Archiving, and what blocks it

    func testAnArchiveAnswerCarriesItsTimestamp() throws {
        let archived = try decode(
            SchedulingUserArchived.self,
            #"{"ok":true,"archived_at":"2026-09-05T12:00:00Z"}"#
        )
        XCTAssertTrue(archived.ok)
        XCTAssertEqual(archived.archivedAt, "2026-09-05T12:00:00Z")
    }

    /// ⚠️ THE TIMESTAMP IS OPTIONAL EVEN ON SUCCESS, so nothing may key "it worked"
    /// on having one. ``SchedulingUserArchived/ok`` is the verdict.
    func testAnArchiveAnswerWithoutATimestampIsStillASuccess() throws {
        let archived = try decode(SchedulingUserArchived.self, #"{"ok":true}"#)
        XCTAssertTrue(archived.ok)
        XCTAssertNil(archived.archivedAt)
    }

    /// ⛔ EVERY FIELD OF THE BLOCKING-BOOKINGS PROJECTION IS REQUIRED, which is the
    /// opposite of ``SchedulingBooking`` and is not a contradiction: the fork
    /// assembles this one for a single question and joins what it needs to answer
    /// it.
    func testAnUpcomingBookingCarriesTheJoinedEventTypeAndAttendee() throws {
        let booking = try decode(
            SchedulingUpcomingBooking.self,
            #"""
            {"id":"bk_3","start_at":"2026-09-18T15:00:00Z","end_at":"2026-09-18T15:30:00Z",
             "event_type_name":"Site visit","event_type_slug":"site-visit",
             "attendee_name":"Dana Booker","attendee_email":"dana@test"}
            """#
        )
        XCTAssertEqual(booking.id, "bk_3")
        XCTAssertEqual(booking.startAt, "2026-09-18T15:00:00Z")
        XCTAssertEqual(booking.endAt, "2026-09-18T15:30:00Z")
        XCTAssertEqual(booking.eventTypeName, "Site visit")
        XCTAssertEqual(booking.eventTypeSlug, "site-visit")
        XCTAssertEqual(booking.attendeeName, "Dana Booker")
        XCTAssertEqual(booking.attendeeEmail, "dana@test")
    }

    func testAnUpcomingBookingMissingItsAttendeeIsRefused() {
        XCTAssertThrowsError(
            try decode(
                SchedulingUpcomingBooking.self,
                #"""
                {"id":"bk_4","start_at":"a","end_at":"b","event_type_name":"X",
                 "event_type_slug":"x","attendee_name":"Dana"}
                """#
            )
        )
    }

    // MARK: - Teams

    func testATeamWithMembersCarriesEachOnesRoutingPriority() throws {
        let team = try decode(
            SchedulingTeam.self,
            #"""
            {"id":"t_1","name":"Sales","slug":"sales","created_at":"2026-09-01T09:30:00Z",
             "member_count":2,
             "members":[{"id":"u_1","name":"Contract Member","email":"a@test",
                         "avatar_url":"https://example.test/a.png","routing_priority":0,
                         "archived":false},
                        {"id":"u_2","name":"Rotation Host","email":"r@test",
                         "routing_priority":5,"archived":false}]}
            """#
        )
        XCTAssertEqual(team.id, "t_1")
        XCTAssertEqual(team.name, "Sales")
        XCTAssertEqual(team.slug, "sales")
        XCTAssertEqual(team.createdAt, "2026-09-01T09:30:00Z")
        XCTAssertEqual(team.memberCount, 2)
        XCTAssertEqual(team.members?.count, 2)
        // ⛔ `0` IS A REAL PRIORITY AND NOT AN ABSENCE — it is the front of the
        // rotation, which is why the field is non-optional and must never default.
        XCTAssertEqual(team.members?[0].routingPriority, 0)
        XCTAssertEqual(team.members?[0].avatarUrl, "https://example.test/a.png")
        XCTAssertEqual(team.members?[0].email, "a@test")
        XCTAssertEqual(team.members?[0].name, "Contract Member")
        XCTAssertEqual(team.members?[0].id, "u_1")
        XCTAssertFalse(team.members?[0].archived ?? true)
        XCTAssertEqual(team.members?[1].routingPriority, 5)
        // ⚠️ ABSENT rather than null: a member with no avatar omits the key.
        XCTAssertNil(team.members?[1].avatarUrl)
    }

    /// ⛔ AN EMPTY TEAM ANSWERS `members: null`, NOT `[]`, on both reads that serve
    /// it. ⚠️ And `member_count` agrees at `0`, which is what makes the count the
    /// field to trust after a write rather than the array.
    func testAnEmptyTeamDecodesAnExplicitNullForItsMembers() throws {
        let team = try decode(
            SchedulingTeam.self,
            #"""
            {"id":"t_2","name":"Support","slug":"support","created_at":"2026-09-02T09:30:00Z",
             "member_count":0,"members":null}
            """#
        )
        XCTAssertNil(team.members)
        XCTAssertEqual(team.memberCount, 0)
    }

    /// ⚠️ ABSENT IS NOT `0` ON `member_count`, so nothing may render a zero it was
    /// not sent — and the `members` key may be absent rather than null here too.
    func testATeamWithNeitherMembersNorACountStillDecodes() throws {
        let team = try decode(SchedulingTeam.self, #"{"id":"t_3","name":"Ops","slug":"ops"}"#)
        XCTAssertNil(team.memberCount)
        XCTAssertNil(team.members)
        XCTAssertNil(team.createdAt)
    }

    /// ⛔ THE BADGE ON A USER ROW IS NOT ``SchedulingTeam``. It carries two keys,
    /// and a shared type would model four more that never arrive.
    func testTheTeamBadgeOnAUserRowIsTwoKeys() throws {
        let badge = try decode(SchedulingUserTeam.self, #"{"id":"t_1","name":"Sales"}"#)
        XCTAssertEqual(badge.id, "t_1")
        XCTAssertEqual(badge.name, "Sales")
    }

    func testATeamMemberWithoutARoutingPriorityIsRefused() {
        XCTAssertThrowsError(
            try decode(
                SchedulingTeamMember.self,
                #"{"id":"u_1","name":"Contract Member","email":"a@test","archived":false}"#
            )
        )
    }
}
