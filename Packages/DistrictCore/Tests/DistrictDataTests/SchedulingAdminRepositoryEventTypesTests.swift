import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The thirteen `eventTypes.*` wrappers, asserted on the BODY they send and the
/// value they hand back.
///
/// ⛔ THE BODY IS COMPARED AS A PARSED `JSONValue`, NOT AS A STRING, AND THAT IS A
/// DELIBERATE WEAKENING OF ONE THING TO STRENGTHEN ANOTHER. `SchedulingAdminRepositoryTests`
/// already pins the exact bytes of a request, key order included, so the wire
/// format has a proof; what these tests are for is WHICH KEYS a body carries, and
/// at 28 params a string literal would be unreadable and would fail on a reordering
/// that changes nothing. ``JSONValue`` is `Equatable`, so an extra key, a dropped
/// key and a wrong value all still fail.
///
/// ⛔ EVERY PATCH IS ASSERTED IN BOTH POLARITIES. `JSONValue.object(_:)` drops a nil
/// pair, so "leave alone" is spelled by ABSENCE — and a test that only ever sent a
/// fully populated draft would pass identically against a builder that ignored nil
/// and sent nulls, which the server reads as a different instruction.
final class SchedulingAdminRepositoryEventTypesTests: XCTestCase {
    private func repository(_ transport: RepositoryTransport) -> SchedulingAdminRepository {
        SchedulingAdminRepository(client: .repositoryTest(transport), reportUnknownOp: { _ in })
    }

    private func body(_ transport: RepositoryTransport) throws -> JSONValue {
        let raw = try XCTUnwrap(transport.bodies.first)
        return try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
    }

    private func assertEnvelope(
        _ transport: RepositoryTransport,
        op: String,
        params: JSONValue,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let sent = try body(transport)
        XCTAssertEqual(sent["op"], .string(op), file: file, line: line)
        XCTAssertEqual(sent["workspaceId"], .string("ws_1"), file: file, line: line)
        XCTAssertEqual(sent["params"], params, file: file, line: line)
    }

    // MARK: - list / get

    func testListEventTypesUnwrapsTheItemsEnvelope() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"items":[\#(Self.minimalRow)]}}"#)
        let rows = try await repository(transport).listEventTypes(workspaceId: "ws_1")
        XCTAssertEqual(rows.map(\.id), ["et_1"])
        // ⛔ AN OP THAT TAKES NOTHING SENDS `"params":{}`, NOT A DROPPED KEY.
        try assertEnvelope(transport, op: "eventTypes.list", params: .object([]))
    }

    /// ⛔ THE PATH KEY IS STILL IN THE BODY. The server validates against a schema
    /// that REQUIRES `slug` and strips it afterwards; a client that removed it
    /// first would get a 400 naming the field it was being tidy about.
    func testGetEventTypeSendsTheSlugInTheBody() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.minimalRow)}"#)
        let row = try await repository(transport).eventType(workspaceId: "ws_1", slug: "intro-call")
        XCTAssertEqual(row.id, "et_1")
        try assertEnvelope(transport, op: "eventTypes.get", params: .object([("slug", .string("intro-call"))]))
    }

    // MARK: - create

    /// ⚠️ THE MINIMUM THE SCHEMA ACCEPTS. Eleven optional pairs are dropped, which
    /// is what makes this the test that would catch a builder sending nulls.
    func testCreateEventTypeSendsOnlyTheFieldsThatWereSet() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.minimalRow)}"#)
        let draft = SchedulingEventTypeDraft(slug: "intro-call", name: "Intro call", durationMinutes: 30)
        _ = try await repository(transport).createEventType(workspaceId: "ws_1", draft: draft)
        try assertEnvelope(
            transport,
            op: "eventTypes.create",
            params: .object([
                ("slug", .string("intro-call")),
                ("name", .string("Intro call")),
                ("duration_minutes", .integer(30)),
            ])
        )
    }

    func testCreateEventTypeCarriesEveryFieldTheSchemaAccepts() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.minimalRow)}"#)
        var draft = SchedulingEventTypeDraft(slug: "intro-call", name: "Intro call", durationMinutes: 30)
        draft.description = "A short call."
        draft.slotIntervalMinutes = 15
        draft.locationType = "phone"
        draft.locationValue = "+14165550134"
        draft.routingMode = "round_robin"
        draft.bufferBeforeMinutes = 5
        draft.bufferAfterMinutes = 10
        draft.minNoticeMinutes = 120
        draft.maxFutureDays = 60
        draft.maxActiveBookings = 3
        draft.showTakenSlots = true
        _ = try await repository(transport).createEventType(workspaceId: "ws_1", draft: draft)
        try assertEnvelope(
            transport,
            op: "eventTypes.create",
            params: .object([
                ("slug", .string("intro-call")),
                ("name", .string("Intro call")),
                ("duration_minutes", .integer(30)),
                ("description", .string("A short call.")),
                ("slot_interval_minutes", .integer(15)),
                ("location_type", .string("phone")),
                ("location_value", .string("+14165550134")),
                ("routing_mode", .string("round_robin")),
                ("buffer_before_minutes", .integer(5)),
                ("buffer_after_minutes", .integer(10)),
                ("min_notice_minutes", .integer(120)),
                ("max_future_days", .integer(60)),
                ("max_active_bookings", .integer(3)),
                ("show_taken_slots", .bool(true)),
            ])
        )
    }

    // MARK: - patch

    /// ⛔ AN EMPTY CHANGE SET STILL SENDS THE SLUG, because the slug is the ADDRESS
    /// and not a change. ⚠️ It is also still a write against the workspace's hourly
    /// budget, which is why a Save button should compare before calling.
    func testPatchEventTypeWithNoChangesSendsOnlyTheSlug() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.minimalRow)}"#)
        _ = try await repository(transport).patchEventType(
            workspaceId: "ws_1",
            slug: "intro-call",
            changes: SchedulingEventTypeChanges()
        )
        try assertEnvelope(transport, op: "eventTypes.patch", params: .object([("slug", .string("intro-call"))]))
    }

    func testPatchEventTypeCarriesEveryChangeableField() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.minimalRow)}"#)
        _ = try await repository(transport).patchEventType(
            workspaceId: "ws_1",
            slug: "intro-call",
            changes: Self.everyChange
        )
        try assertEnvelope(transport, op: "eventTypes.patch", params: Self.everyChangeParams)
    }

    /// ⛔ `[]` IS SENT AND IS NOT A DROP. An empty reminders array turns every
    /// reminder off; nil leaves the schedule alone. One keystroke apart, and the
    /// difference is whether a customer gets a reminder email.
    func testAnEmptyRemindersArrayIsSentRatherThanDropped() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.minimalRow)}"#)
        var changes = SchedulingEventTypeChanges()
        changes.reminders = []
        _ = try await repository(transport).patchEventType(
            workspaceId: "ws_1",
            slug: "intro-call",
            changes: changes
        )
        try assertEnvelope(
            transport,
            op: "eventTypes.patch",
            params: .object([("slug", .string("intro-call")), ("reminders", .array([]))])
        )
    }

    // MARK: - delete

    /// ⛔ THE DELETE DECODES `SchedulingNoContent` AND DISCARDS IT. Modelling the
    /// sixteen no-body ops as an empty body would decode a `{ok:false}` failure
    /// envelope just as happily; the catalog rewrites a 204 into `{"ok":true}`
    /// before it leaves the route, and this is what asserts that.
    func testDeleteEventTypeSendsTheSlugAndAcceptsTheRewrittenFlag() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"ok":true}}"#)
        try await repository(transport).deleteEventType(workspaceId: "ws_1", slug: "intro-call")
        try assertEnvelope(transport, op: "eventTypes.delete", params: .object([("slug", .string("intro-call"))]))
    }

    // MARK: - Bodies

    private static let minimalRow = #"{"id":"et_1","slug":"intro-call","name":"Intro call","duration_minutes":30}"#

    private static var everyChange: SchedulingEventTypeChanges {
        var changes = SchedulingEventTypeChanges()
        changes.name = "Renamed"
        changes.description = "Changed."
        changes.durationMinutes = 45
        changes.slotIntervalMinutes = 15
        changes.locationType = "link"
        changes.locationValue = "https://example.test/room"
        changes.routingMode = "collective"
        changes.rrStrategy = "soonest"
        changes.bufferBeforeMinutes = 5
        changes.bufferAfterMinutes = 10
        changes.minNoticeMinutes = 120
        changes.maxFutureDays = 60
        changes.maxActiveBookings = 3
        changes.isActive = true
        changes.isPublic = false
        changes.showTakenSlots = true
        changes.archived = false
        changes.msgConfirmation = "m-c"
        changes.msgCancellation = "m-x"
        changes.msgReschedule = "m-r"
        changes.msgReminder = "m-rem"
        changes.msgGreeting = "m-g"
        changes.subjConfirmation = "s-c"
        changes.subjCancellation = "s-x"
        changes.subjReschedule = "s-r"
        changes.subjReminder = "s-rem"
        changes.reminders = [1440, 60]
        return changes
    }

    private static let everyChangeParams = JSONValue.object([
        ("slug", .string("intro-call")),
        ("name", .string("Renamed")),
        ("description", .string("Changed.")),
        ("duration_minutes", .integer(45)),
        ("slot_interval_minutes", .integer(15)),
        ("location_type", .string("link")),
        ("location_value", .string("https://example.test/room")),
        ("routing_mode", .string("collective")),
        ("rr_strategy", .string("soonest")),
        ("buffer_before_minutes", .integer(5)),
        ("buffer_after_minutes", .integer(10)),
        ("min_notice_minutes", .integer(120)),
        ("max_future_days", .integer(60)),
        ("max_active_bookings", .integer(3)),
        ("is_active", .bool(true)),
        ("is_public", .bool(false)),
        ("show_taken_slots", .bool(true)),
        ("archived", .bool(false)),
        ("msg_confirmation", .string("m-c")),
        ("msg_cancellation", .string("m-x")),
        ("msg_reschedule", .string("m-r")),
        ("msg_reminder", .string("m-rem")),
        ("msg_greeting", .string("m-g")),
        ("subj_confirmation", .string("s-c")),
        ("subj_cancellation", .string("s-x")),
        ("subj_reschedule", .string("s-r")),
        ("subj_reminder", .string("s-rem")),
        ("reminders", .array([.integer(1440), .integer(60)])),
    ])
}
