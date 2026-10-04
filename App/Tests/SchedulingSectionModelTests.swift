@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import XCTest

/// The seven section models the register does not cover, driven over the same fake
/// transport.
///
/// ⛔ A SECOND FILE RATHER THAN MORE CASES IN ``SchedulingModelTests``, FOR A LINT CEILING
/// AND NOT A TAXONOMY. `swiftlint --strict` caps a type body at 300 lines and a file at
/// 500; ten models' worth of stub tables reaches both, which is the same pressure that
/// created ``SchedulingModelTestCase``. The factories stay in that one base class so
/// "which repositories does this model take" has a single answer.
///
/// ⛔ AND EVERY CASE HERE ASSERTS A DEGRADATION RATHER THAN A HAPPY PATH. Each of these
/// screens is several independent reads, and the decisions worth pinning are the ones
/// about what a PARTIAL answer is allowed to claim: a missing calendar list is not an
/// empty one, and an unreadable District membership must not accuse every host of
/// having left.
final class SchedulingSectionModelTests: SchedulingModelTestCase {
    // MARK: - Bookings

    /// ⛔ THE CONTEXT LANDS BEFORE PAGE ONE, AND THE ORDER IS THE ASSERTION. The timezone
    /// captions every row and the event-type list resolves every slug, so fetching them
    /// alongside the first page would draw it in the wrong zone with unresolved names and
    /// then rewrite it under the reader.
    @MainActor
    func test_IOS_SCHSECMODEL_01_theBookingsContextLandsBeforeThePage() async {
        let transport = SchedulingTestTransport([
            "status": .readyStatus(),
            "me.get": .me(timezone: "America/Toronto"),
            "eventTypes.list": .data(
                #"{"items":[{"id":"et1","slug":"intro","name":"Intro call","duration_minutes":30}]}"#
            ),
            "bookings.list": .data("""
            {"items":[{"id":"b1","event_type_slug":"intro","start_at":"2026-09-12T14:30:00Z",
            "end_at":"2026-09-12T15:00:00Z","status":"confirmed",
            "attendees":[{"name":"Ada","email":"a@b.com"}]}],"total":1}
            """),
        ])
        let model = bookings(transport)
        await model.load()

        XCTAssertEqual(transport.ops.last, "bookings.list")
        XCTAssertEqual(model.timezone, "America/Toronto")
        XCTAssertTrue(model.canManage)
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.rows.first?.who, "Ada")
        XCTAssertEqual(model.rows.first?.eventType, "Intro call")
    }

    /// ⚠️ AN UNRESOLVED SLUG IS SHOWN RAW RATHER THAN REPLACED, and a failed event-type
    /// read is exactly the case that produces one. The booking genuinely names an event
    /// type this screen could not look up, and the slug is the only true thing left to say
    /// about it; the page still draws.
    @MainActor
    func test_IOS_SCHSECMODEL_02_aFailedEventTypeReadStillDrawsTheRows() async {
        let transport = SchedulingTestTransport([
            "status": .readyStatus(),
            "me.get": .me(),
            "eventTypes.list": .refused("unavailable"),
            "bookings.list": .data("""
            {"items":[{"id":"b1","event_type_slug":"intro","start_at":"2026-09-12T14:30:00Z",
            "end_at":"2026-09-12T15:00:00Z","status":"confirmed"}],"total":1}
            """),
        ])
        let model = bookings(transport)
        await model.load()

        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.rows.first?.eventType, "intro")
        // ⚠️ `bookingWho` falls through to `Someone` for a row with no attendee at all.
        XCTAssertEqual(model.rows.first?.who, "Someone")
    }

    // MARK: - One booking

    /// ⛔ ONE READ, AND A REFUSAL KEEPS ITS OWN SENTENCE. The notes and transcript reads
    /// beside it were retired with meeting recording (2026-10-03), so nothing else may be
    /// asked for.
    @MainActor
    func test_IOS_SCHSECMODEL_03_oneBookingReadsOnlyItsAnswers() async {
        let transport = SchedulingTestTransport([
            "bookings.answers": .refused("unavailable"),
        ])
        let model = bookingDetail(transport)
        await model.load()

        guard case let .failed(answers) = model.answers else {
            return XCTFail("the answers read was refused and must say so")
        }
        XCTAssertEqual(answers.message, SchedulingFailureCopy.unavailable)
        XCTAssertEqual(transport.ops, ["bookings.answers"])
    }

    // MARK: - Calendar

    /// ⛔ A CONNECTION WHOSE CALENDAR READ FAILED IS ABSENT, NOT EMPTY. Recording an empty
    /// array for it would turn "we could not read which calendars are selected" into "none
    /// is selected", which is the distinction the conflict summary exists to keep.
    /// ⚠️ The zoom read failing is silent for the same family of reason: it reports a
    /// separate integration, and failing the screen over it would hide the connections.
    @MainActor
    func test_IOS_SCHSECMODEL_04_anUnreadableCalendarListIsAbsentRatherThanEmpty() async {
        let transport = SchedulingTestTransport([
            "calendar.status": .data("""
            {"connected":true,"configured":true,"connections":[
            {"id":"c_1","provider":"google","account_email":"a@test",
            "is_destination":false,"check_conflicts":true}]}
            """),
            "calendar.connections.calendars.get": .refused("unavailable"),
            "zoom.status": .refused("unavailable"),
        ])
        let model = calendar(transport)
        await model.load()

        XCTAssertEqual(model.state.value?.connections.count, 1)
        XCTAssertNil(model.calendars["c_1"])
        XCTAssertNil(model.zoom)
    }

    // MARK: - Team

    /// ⛔ AN UNREADABLE DISTRICT MEMBERSHIP MUST NOT ACCUSE EVERY HOST OF HAVING LEFT. The
    /// join still runs, so every scheduler user comes back with no District role — which
    /// is the exact shape `strandedHosts` looks for — and the notice is therefore
    /// SUPPRESSED and the degraded flag raised instead.
    @MainActor
    func test_IOS_SCHSECMODEL_05_aFailedMembershipReadSuppressesTheStrandedNotice() async {
        let transport = SchedulingTestTransport([
            "members": .http(503, error: "unavailable"),
            "users.list": .data("""
            [{"id":"u_1","email":"ada@test","name":"Ada","is_admin":false,"is_owner":false,
              "role":"member","archived":false}]
            """),
            "teams.list": .data(#"{"items":[]}"#),
        ])
        let model = team(transport)
        await model.load()

        XCTAssertTrue(model.districtMembersFailed)
        XCTAssertEqual(model.members.value?.count, 1)
        XCTAssertEqual(model.members.value?.first?.state, .host)
        XCTAssertNil(model.strandedNotice)
    }

    /// ⚠️ AND WITH THE MEMBERSHIP READ WORKING, THE SAME SHAPE IS A REAL WARNING. One
    /// scheduler account, no District row, live: that person has left and still holds
    /// bookings. ⛔ Asserted as the pair to the case above so neither side can be tidied
    /// into the other.
    @MainActor
    func test_IOS_SCHSECMODEL_06_aHostWithNoDistrictRowIsStranded() async {
        let transport = SchedulingTestTransport([
            "members": Reply(status: 200, body: #"{"success":true,"members":[]}"#),
            "users.list": .data("""
            [{"id":"u_1","email":"ada@test","name":"Ada","is_admin":false,"is_owner":false,
              "role":"member","archived":false}]
            """),
            "teams.list": .data(#"{"items":[]}"#),
        ])
        let model = team(transport)
        await model.load()

        XCTAssertFalse(model.districtMembersFailed)
        XCTAssertEqual(model.strandedNotice?.contains("Ada"), true)
    }

    // MARK: - Settings

    /// ⛔ THE SECOND TAB IS THE BOOKING ASSISTANT AND READS `settings.llm.get` ALONE. It
    /// was "Recordings and notes" and read storage and the notetaker as well, until both
    /// were retired with meeting recording (2026-10-03).
    @MainActor
    func test_IOS_SCHSECMODEL_07_theAssistantTabReadsOnlyTheAssistant() async {
        let transport = SchedulingTestTransport([
            "settings.branding.get": .data(#"{"business_name":"Acme"}"#),
            "settings.llm.get": .data(#"{"enabled":true,"extra_instructions":"Ask for the location."}"#),
        ])
        let model = settings(transport)
        await model.loadCurrentTab()
        await model.selectTab("assistant")

        XCTAssertEqual(transport.ops, ["settings.branding.get", "settings.llm.get"])
        XCTAssertEqual(model.assistant?.value?.enabled, true)
        XCTAssertEqual(model.assistant?.value?.extraInstructions, "Ask for the location.")
    }

    /// ⛔ THE PROFILE AND NOTIFICATIONS TABS SHARE ONE `me.get`, because they are two views
    /// of one payload. Reading it again on the second tab would spend a request to display
    /// fields the client is already holding.
    @MainActor
    func test_IOS_SCHSECMODEL_09_theProfileAndNotificationTabsShareOneRead() async {
        let transport = SchedulingTestTransport([
            "settings.branding.get": .data(#"{"business_name":"Acme"}"#),
            "me.get": .me(),
        ])
        let model = settings(transport)
        await model.loadCurrentTab()
        XCTAssertEqual(transport.ops, ["settings.branding.get"])

        await model.selectTab("profile")
        await model.selectTab("notifications")
        XCTAssertEqual(transport.ops, ["settings.branding.get", "me.get"])
        XCTAssertNotNil(model.profile?.value)

        // ⚠️ Pull-to-refresh clears first, so it is the one way to spend a second read.
        await model.reload()
        XCTAssertEqual(transport.ops.filter { $0 == "me.get" }.count, 2)
    }

    // MARK: - Developer

    /// ⚠️ THE TABS LOAD ON DEMAND AND ARE IDEMPOTENT, so returning to one already read
    /// costs nothing. ⛔ The context is read ONCE for the screen: the timezone captions
    /// three of the four tables and the public host builds the MCP address, and neither
    /// changes with the tab.
    @MainActor
    func test_IOS_SCHSECMODEL_10_developerTabsLoadOnceAndOnDemand() async {
        let transport = SchedulingTestTransport([
            "status": .readyStatus(host: "acme.example.com"),
            "me.get": .me(timezone: "America/Toronto"),
            "apiKeys.list": .data(#"{"items":[{"id":"key_1","name":"Zapier"}]}"#),
            "webhooks.list": .data(
                #"{"items":[{"id":"wh_1","url":"https://hooks.test/a","events":["booking.created"]}]}"#
            ),
        ])
        let model = developer(transport)
        await model.loadContext()

        XCTAssertEqual(model.timezone, "America/Toronto")
        XCTAssertEqual(model.publicHost, "acme.example.com")
        XCTAssertEqual(model.keys?.value?.count, 1)

        await model.selectTab("webhooks")
        await model.selectTab("keys")
        // ⚠️ One read each, and no second `apiKeys.list` for the return visit.
        XCTAssertEqual(transport.ops.filter { $0 == "apiKeys.list" }.count, 1)
        XCTAssertEqual(model.webhooks?.value?.count, 1)
    }

    /// ⚠️ A TAB'S OWN REFUSAL IS THE TAB'S. `apps` is the one with no stub here, so it
    /// answers a 500 the model reports on that tab alone while the keys it already holds
    /// stay on screen.
    @MainActor
    func test_IOS_SCHSECMODEL_11_aRefusedTabDoesNotDisturbTheOneBesideIt() async {
        let transport = SchedulingTestTransport([
            "status": .readyStatus(),
            "me.get": .me(),
            "apiKeys.list": .data(#"{"items":[{"id":"key_1","name":"Zapier"}]}"#),
            "oauth.connections.list": .refused("unavailable"),
        ])
        let model = developer(transport)
        await model.loadContext()
        await model.selectTab("apps")

        guard case let .failed(failure) = model.apps else {
            return XCTFail("the apps tab must report its own failure")
        }
        XCTAssertEqual(failure.message, SchedulingFailureCopy.unavailable)
        XCTAssertEqual(model.keys?.value?.count, 1)
    }
}

/// ⚠️ THE STUB TABLE'S VALUE TYPE, SPELLED ONCE. Every fixture above reaches it through a
/// static helper; the workspace-members row is the one answer on this surface that is not
/// an admin envelope at all, so it is built literally.
private typealias Reply = SchedulingTestTransport.Reply
