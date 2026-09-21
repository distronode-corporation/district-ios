import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The nine `availability.*` wrappers, asserted on the BODY they send and the value
/// they hand back.
///
/// ⛔ THE BODY IS COMPARED AS A PARSED `JSONValue` RATHER THAN AS A STRING, and the
/// three private helpers below are DUPLICATED from the event-type suites rather
/// than lifted into a shared support file. `private` is file scope, so a copy here
/// cannot collide with a third that another suite adds under the same obvious
/// name — a live concern on a surface this wide.
///
/// ⛔ EVERY PATCH IS ASSERTED IN BOTH POLARITIES, because `JSONValue.object(_:)`
/// drops a nil pair: "leave alone" is spelled by ABSENCE, and a suite that only
/// ever sent a populated patch would pass identically against a builder that sent
/// explicit nulls — a different instruction to the server.
final class SchedulingAdminAvailabilityRepoTests: XCTestCase {
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

    // MARK: - Weekly rules

    /// ⛔ NO `eventTypeId` SENDS `"params":{}` — an unfiltered list. ⚠️ And a
    /// FILTERED list is not a superset of it: a rule with a null `event_type_id`
    /// governs every event type and does not come back under a filter, so the rules
    /// that actually apply to one event type are two calls unioned.
    func testRulesListWithNoFilterSendsAnEmptyParamsObject() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"items":[\#(Self.globalRule)]}}"#)
        let rules = try await repository(transport).availabilityRules(workspaceId: "ws_1")
        XCTAssertEqual(rules.map(\.id), ["rule_2"])
        XCTAssertNil(rules.first?.eventTypeId)
        try assertEnvelope(transport, op: "availability.rules.list", params: .object([]))
    }

    func testRulesListCarriesTheEventTypeFilterWhenGiven() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"items":[\#(Self.scopedRule)]}}"#)
        let rules = try await repository(transport).availabilityRules(workspaceId: "ws_1", eventTypeId: "et_1")
        XCTAssertEqual(rules.first?.eventTypeId, "et_1")
        try assertEnvelope(
            transport,
            op: "availability.rules.list",
            params: .object([("event_type_id", .string("et_1"))])
        )
    }

    /// ⚠️ A nil `eventTypeId` DROPS THE KEY, which the fork reads as the global
    /// rule. The schema is `.nullable().optional()`, so absent and null are the
    /// same instruction there and this sends the absent spelling.
    func testCreateRuleDropsTheEventTypeToMakeItGlobal() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.globalRule)}"#)
        let rule = try await repository(transport).createAvailabilityRule(
            workspaceId: "ws_1",
            eventTypeId: nil,
            dayOfWeek: 3,
            startTime: "10:30",
            endTime: "15:00"
        )
        XCTAssertNil(rule.eventTypeId)
        try assertEnvelope(
            transport,
            op: "availability.rules.create",
            params: .object([
                ("day_of_week", .integer(3)),
                ("start_time", .string("10:30")),
                ("end_time", .string("15:00")),
            ])
        )
    }

    func testCreateRuleCarriesTheEventTypeWhenItIsScoped() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.scopedRule)}"#)
        let rule = try await repository(transport).createAvailabilityRule(
            workspaceId: "ws_1",
            eventTypeId: "et_1",
            dayOfWeek: 1,
            startTime: "09:00",
            endTime: "17:00"
        )
        XCTAssertEqual(rule.eventTypeId, "et_1")
        XCTAssertEqual(rule.dayOfWeek, 1)
        try assertEnvelope(
            transport,
            op: "availability.rules.create",
            params: .object([
                ("event_type_id", .string("et_1")),
                ("day_of_week", .integer(1)),
                ("start_time", .string("09:00")),
                ("end_time", .string("17:00")),
            ])
        )
    }

    /// ⛔ THE PATH KEY STAYS IN THE BODY, and an empty patch is just the id.
    func testPatchRuleWithNoChangesSendsOnlyTheId() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.scopedRule)}"#)
        _ = try await repository(transport).patchAvailabilityRule(workspaceId: "ws_1", id: "rule_1")
        try assertEnvelope(transport, op: "availability.rules.patch", params: .object([("id", .string("rule_1"))]))
    }

    /// ⛔ `event_type_id` IS NOT PATCHABLE AND THERE IS NO ARGUMENT FOR IT. Moving a
    /// rule between event types is a delete and a create.
    func testPatchRuleCarriesTheThreeFieldsTheSchemaAccepts() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.scopedRule)}"#)
        _ = try await repository(transport).patchAvailabilityRule(
            workspaceId: "ws_1",
            id: "rule_1",
            dayOfWeek: 5,
            startTime: "08:00",
            endTime: "12:30"
        )
        try assertEnvelope(
            transport,
            op: "availability.rules.patch",
            params: .object([
                ("id", .string("rule_1")),
                ("day_of_week", .integer(5)),
                ("start_time", .string("08:00")),
                ("end_time", .string("12:30")),
            ])
        )
    }

    func testDeleteRuleSendsTheIdAndAcceptsTheRewrittenFlag() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"ok":true}}"#)
        try await repository(transport).deleteAvailabilityRule(workspaceId: "ws_1", id: "rule_1")
        try assertEnvelope(transport, op: "availability.rules.delete", params: .object([("id", .string("rule_1"))]))
    }

    // MARK: - Dated overrides

    /// ⚠️ THE LIST TAKES NO PARAMS AT ALL — no date window, no event type. Any
    /// narrowing is this side's job.
    func testOverridesListSendsAnEmptyParamsObject() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"items":[\#(Self.groupedOverride)]}}"#)
        let rows = try await repository(transport).availabilityOverrides(workspaceId: "ws_1")
        XCTAssertEqual(rows.map(\.id), ["ovr_1"])
        XCTAssertEqual(rows.first?.groupId, "grp_1")
        try assertEnvelope(transport, op: "availability.overrides.list", params: .object([]))
    }

    /// ⛔ NO `endDate` ⇒ THE ROW ARM. A single-date override answers a row, and the
    /// union is disambiguated on `id` rather than on `group_id`.
    func testCreateOverrideWithoutAnEndDateAnswersTheRow() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.allDayOverride)}"#)
        let created = try await repository(transport).createAvailabilityOverride(
            workspaceId: "ws_1",
            draft: SchedulingOverrideDraft(date: "2026-09-25", reason: "day_off")
        )
        guard case let .single(row) = created else {
            return XCTFail("expected the row arm, got \(created)")
        }
        XCTAssertEqual(row.id, "ovr_2")
        XCTAssertNil(row.startTime)
        try assertEnvelope(
            transport,
            op: "availability.overrides.create",
            params: .object([("date", .string("2026-09-25")), ("reason", .string("day_off"))])
        )
    }

    /// ⛔ AN `endDate` ⇒ THE SUMMARY ARM, WHICH CARRIES NO `id` AT ALL. `start` and
    /// `end` there are DATES, not the `HH:MM` times this same draft sends.
    func testCreateOverrideWithARangeAnswersTheGroupSummary() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.rangeSummary)}"#)
        var draft = SchedulingOverrideDraft(date: "2026-12-24", reason: "out_of_office")
        draft.endDate = "2026-12-31"
        let created = try await repository(transport).createAvailabilityOverride(workspaceId: "ws_1", draft: draft)
        guard case let .range(group) = created else {
            return XCTFail("expected the range arm, got \(created)")
        }
        XCTAssertEqual(group.groupId, "grp_2")
        XCTAssertEqual(group.days, 8)
        XCTAssertEqual(group.start, "2026-12-24")
        XCTAssertEqual(group.end, "2026-12-31")
        try assertEnvelope(
            transport,
            op: "availability.overrides.create",
            params: .object([
                ("date", .string("2026-12-24")),
                ("reason", .string("out_of_office")),
                ("end_date", .string("2026-12-31")),
            ])
        )
    }

    /// ⛔ THE TIMES ONLY MEAN ANYTHING UNDER `custom_hours`, and an all-day block
    /// sends neither — which is why both polarities are here rather than one
    /// fully-populated draft.
    func testCreateOverrideCarriesCustomHoursWhenTheyAreSet() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.groupedOverride)}"#)
        var draft = SchedulingOverrideDraft(date: "2026-09-24", reason: "custom_hours")
        draft.startTime = "12:00"
        draft.endTime = "16:00"
        _ = try await repository(transport).createAvailabilityOverride(workspaceId: "ws_1", draft: draft)
        try assertEnvelope(
            transport,
            op: "availability.overrides.create",
            params: .object([
                ("date", .string("2026-09-24")),
                ("reason", .string("custom_hours")),
                ("start_time", .string("12:00")),
                ("end_time", .string("16:00")),
            ])
        )
    }

    func testPatchOverrideWithNoChangesSendsOnlyTheId() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.allDayOverride)}"#)
        let row = try await repository(transport).patchAvailabilityOverride(workspaceId: "ws_1", id: "ovr_2")
        XCTAssertEqual(row.id, "ovr_2")
        try assertEnvelope(
            transport,
            op: "availability.overrides.patch",
            params: .object([("id", .string("ovr_2"))])
        )
    }

    /// ⛔ THE DATE IS NOT PATCHABLE AND THERE IS NO ARGUMENT FOR IT.
    func testPatchOverrideCarriesTheThreeFieldsTheSchemaAccepts() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":\#(Self.groupedOverride)}"#)
        _ = try await repository(transport).patchAvailabilityOverride(
            workspaceId: "ws_1",
            id: "ovr_1",
            reason: "custom_hours",
            startTime: "12:00",
            endTime: "16:00"
        )
        try assertEnvelope(
            transport,
            op: "availability.overrides.patch",
            params: .object([
                ("id", .string("ovr_1")),
                ("reason", .string("custom_hours")),
                ("start_time", .string("12:00")),
                ("end_time", .string("16:00")),
            ])
        )
    }

    /// ⚠️ ONE DAY, AND ON A ROW FROM A RANGE THAT LEAVES THE REST IN PLACE.
    func testDeleteOverrideSendsTheRowId() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"ok":true}}"#)
        try await repository(transport).deleteAvailabilityOverride(workspaceId: "ws_1", id: "ovr_1")
        try assertEnvelope(
            transport,
            op: "availability.overrides.delete",
            params: .object([("id", .string("ovr_1"))])
        )
    }

    /// ⛔ THE PARAM IS `groupId`, camelCase, ALONE IN THIS FAMILY. Every other key
    /// these ops take is snake_case; sending `group_id` here is a 400. This is the
    /// assertion that keeps the copy honest.
    func testDeleteOverrideGroupSendsCamelCaseGroupId() async throws {
        let transport = RepositoryTransport(json: #"{"ok":true,"data":{"ok":true}}"#)
        try await repository(transport).deleteAvailabilityOverrideGroup(workspaceId: "ws_1", groupId: "grp_1")
        try assertEnvelope(
            transport,
            op: "availability.overrides.deleteGroup",
            params: .object([("groupId", .string("grp_1"))])
        )
    }

    // MARK: - Bodies

    private static let scopedRule = #"""
    {"id":"rule_1","event_type_id":"et_1","day_of_week":1,"start_time":"09:00","end_time":"17:00"}
    """#

    private static let globalRule = #"""
    {"id":"rule_2","event_type_id":null,"day_of_week":3,"start_time":"10:30","end_time":"15:00"}
    """#

    private static let groupedOverride = #"""
    {"id":"ovr_1","date":"2026-09-24","is_available":true,"reason":"custom_hours",
     "start_time":"12:00","end_time":"16:00","group_id":"grp_1"}
    """#

    private static let allDayOverride = #"""
    {"id":"ovr_2","date":"2026-09-25","is_available":false,"reason":"day_off",
     "start_time":null,"end_time":null}
    """#

    private static let rangeSummary = #"""
    {"group_id":"grp_2","reason":"out_of_office","start":"2026-12-24","end":"2026-12-31","days":8}
    """#
}
