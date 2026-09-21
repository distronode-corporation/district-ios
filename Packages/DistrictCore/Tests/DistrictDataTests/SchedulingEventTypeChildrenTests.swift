import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The five `eventTypes.*` wrappers that address something HANGING OFF an event
/// type — its hosts, its test email, its booking questions and its slots.
///
/// ⛔ SPLIT FROM `SchedulingAdminRepositoryEventTypesTests.swift` FOR SwiftLint's
/// 300-line `type_body_length`, which `--strict` promotes to an error. The two
/// files share their helpers by DUPLICATING the three private ones rather than
/// lifting them into a support file: `private` is file scope, so two copies cannot
/// collide with a third that another suite adds under the same obvious name, a
/// live concern on a surface this wide.
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
final class SchedulingEventTypeChildrenTests: XCTestCase {
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

    // MARK: - hosts

    func testEventTypeHostsUnwrapsTheItemsEnvelope() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"items":[\#(Self.hostRow)]}}"#)
        let hosts = try await repository(transport).eventTypeHosts(workspaceId: "ws_1", slug: "intro-call")
        XCTAssertEqual(hosts.map(\.userId), ["su_1"])
        try assertEnvelope(transport, op: "eventTypes.hosts.get", params: .object([("slug", .string("intro-call"))]))
    }

    /// ⛔ A FULL REPLACEMENT, AND THE ANSWER IS THE LIST RATHER THAN AN ECHO: the
    /// rows come back with the `name`, `email` and `avatar_url` the request never
    /// carried, because the handler re-dispatches into the read.
    func testPutEventTypeHostsSendsEveryAssignmentAndReadsTheListBack() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"items":[\#(Self.hostRow)]}}"#)
        let hosts = try await repository(transport).putEventTypeHosts(
            workspaceId: "ws_1",
            slug: "intro-call",
            hosts: [
                SchedulingHostAssignment(userId: "su_1", role: "required", priority: 0),
                SchedulingHostAssignment(userId: "su_2", role: "rotation", priority: 2),
            ]
        )
        XCTAssertEqual(hosts.first?.email, "member@distronode.test")
        try assertEnvelope(
            transport,
            op: "eventTypes.hosts.put",
            params: .object([
                ("slug", .string("intro-call")),
                ("hosts", .array([
                    .object([("user_id", .string("su_1")), ("role", .string("required")), ("priority", .integer(0))]),
                    .object([("user_id", .string("su_2")), ("role", .string("rotation")), ("priority", .integer(2))]),
                ])),
            ])
        )
    }

    /// ⛔ NO RECIPIENT ARGUMENT. The fork addresses the calling member's own
    /// scheduler address; `to` comes back rather than going out.
    func testSendTestEmailNamesTheTemplateAndReadsTheRecipientBack() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"sent":true,"to":"member@distronode.test"}}"#)
        let result = try await repository(transport).sendEventTypeTestEmail(
            workspaceId: "ws_1",
            slug: "intro-call",
            type: "reminder"
        )
        XCTAssertTrue(result.sent)
        XCTAssertEqual(result.to, "member@distronode.test")
        try assertEnvelope(
            transport,
            op: "eventTypes.testEmail",
            params: .object([("slug", .string("intro-call")), ("type", .string("reminder"))])
        )
    }

    // MARK: - questions

    func testQuestionsListSendsTheSlugAndUnwrapsTheItems() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"items":[\#(Self.questionRow)]}}"#)
        let questions = try await repository(transport).eventTypeQuestions(workspaceId: "ws_1", slug: "intro-call")
        XCTAssertEqual(questions.map(\.id), ["q_1"])
        try assertEnvelope(
            transport,
            op: "eventTypes.questions.list",
            params: .object([("slug", .string("intro-call"))])
        )
    }

    /// ⚠️ `position` AND `options` ARE DROPPED WHEN UNSET, which is what lets the
    /// fork append rather than insert at the top.
    func testCreateQuestionSendsTheRequiredThreeAndDropsTheRest() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.questionRow)}"#)
        let draft = SchedulingQuestionDraft(label: "Anything to read first?", type: "text", required: false)
        _ = try await repository(transport).createEventTypeQuestion(
            workspaceId: "ws_1",
            slug: "intro-call",
            draft: draft
        )
        try assertEnvelope(
            transport,
            op: "eventTypes.questions.create",
            params: .object([
                ("slug", .string("intro-call")),
                ("label", .string("Anything to read first?")),
                ("type", .string("text")),
                ("required", .bool(false)),
            ])
        )
    }

    func testCreateQuestionCarriesOptionsAndPositionWhenSet() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.questionRow)}"#)
        var draft = SchedulingQuestionDraft(label: "Which product?", type: "select", required: true)
        draft.options = ["District", "Ledger"]
        draft.position = 0
        _ = try await repository(transport).createEventTypeQuestion(
            workspaceId: "ws_1",
            slug: "intro-call",
            draft: draft
        )
        try assertEnvelope(
            transport,
            op: "eventTypes.questions.create",
            params: .object([
                ("slug", .string("intro-call")),
                ("label", .string("Which product?")),
                ("type", .string("select")),
                ("required", .bool(true)),
                ("options", .array([.string("District"), .string("Ledger")])),
                ("position", .integer(0)),
            ])
        )
    }

    /// ⚠️ TWO PATH KEYS, AND BOTH STAY IN THE BODY.
    func testPatchQuestionWithNoChangesSendsBothPathKeysOnly() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.questionRow)}"#)
        _ = try await repository(transport).patchEventTypeQuestion(
            workspaceId: "ws_1",
            slug: "intro-call",
            id: "q_1",
            changes: SchedulingQuestionChanges()
        )
        try assertEnvelope(
            transport,
            op: "eventTypes.questions.patch",
            params: .object([("slug", .string("intro-call")), ("id", .string("q_1"))])
        )
    }

    func testPatchQuestionCarriesEveryChangeableField() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.questionRow)}"#)
        var changes = SchedulingQuestionChanges()
        changes.label = "Which product?"
        changes.type = "select"
        changes.options = ["District"]
        changes.required = true
        changes.position = 2
        _ = try await repository(transport).patchEventTypeQuestion(
            workspaceId: "ws_1",
            slug: "intro-call",
            id: "q_1",
            changes: changes
        )
        try assertEnvelope(
            transport,
            op: "eventTypes.questions.patch",
            params: .object([
                ("slug", .string("intro-call")),
                ("id", .string("q_1")),
                ("label", .string("Which product?")),
                ("type", .string("select")),
                ("options", .array([.string("District")])),
                ("required", .bool(true)),
                ("position", .integer(2)),
            ])
        )
    }

    func testDeleteQuestionSendsBothPathKeys() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"ok":true}}"#)
        try await repository(transport).deleteEventTypeQuestion(workspaceId: "ws_1", slug: "intro-call", id: "q_1")
        try assertEnvelope(
            transport,
            op: "eventTypes.questions.delete",
            params: .object([("slug", .string("intro-call")), ("id", .string("q_1"))])
        )
    }

    // MARK: - slots

    /// ⚠️ EVERY ARGUMENT AFTER THE SLUG IS DROPPED WHEN UNSET, and the fork then
    /// picks its own window and its own zone.
    func testSlotsWithNoWindowSendsTheSlugAlone() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"slots":[]}}"#)
        let slots = try await repository(transport).eventTypeSlots(workspaceId: "ws_1", slug: "intro-call")
        XCTAssertEqual(slots.slots, [])
        XCTAssertNil(slots.taken)
        try assertEnvelope(transport, op: "eventTypes.slots", params: .object([("slug", .string("intro-call"))]))
    }

    func testSlotsCarriesTheWindowAndTheZoneWhenGiven() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.slotsBody)}"#)
        let slots = try await repository(transport).eventTypeSlots(
            workspaceId: "ws_1",
            slug: "intro-call",
            from: "2026-09-14",
            to: "2026-09-21",
            tz: "America/Toronto"
        )
        XCTAssertEqual(slots.slots.count, 1)
        XCTAssertNil(slots.slots.first?.hostIds)
        XCTAssertEqual(slots.hosts?["su_1"]?.name, "Contract Member")
        XCTAssertEqual(slots.taken?.count, 1)
        try assertEnvelope(
            transport,
            op: "eventTypes.slots",
            params: .object([
                ("slug", .string("intro-call")),
                ("from", .string("2026-09-14")),
                ("to", .string("2026-09-21")),
                ("tz", .string("America/Toronto")),
            ])
        )
    }

    // MARK: - Bodies

    private static let minimalRow = #"{"id":"et_1","slug":"intro-call","name":"Intro call","duration_minutes":30}"#

    private static let hostRow = #"""
    {"user_id":"su_1","name":"Contract Member","email":"member@distronode.test",
     "role":"required","priority":0,"archived":false}
    """#

    private static let questionRow = #"""
    {"id":"q_1","event_type_id":"et_1","label":"Which product?","type":"select",
     "options":["District"],"required":true,"position":0}
    """#

    private static let slotsBody = #"""
    {"slots":[{"start":"2026-09-14T13:00:00Z","end":"2026-09-14T13:30:00Z","host_ids":null}],
     "hosts":{"su_1":{"name":"Contract Member","avatar_url":""}},
     "taken":[{"start":"2026-09-14T15:00:00Z","end":"2026-09-14T15:30:00Z","host_ids":null}]}
    """#
}
