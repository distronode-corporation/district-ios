@testable import DistrictAI
import DistrictData
import DistrictModel
import Foundation
import XCTest

/// Who can be booked, and how the next booking reaches them.
@MainActor
final class SchedulingWritesHostsTests: XCTestCase {
    /// ⛔ TWO OPS IN A FIXED ORDER, HOSTS FIRST. `routing_mode` and `rr_strategy`
    /// are columns on the EVENT TYPE, so patching them before the host list landed
    /// would leave a round-robin event type pointing at hosts that had not arrived.
    func testASaveSendsTheHostListBeforeTheRoutingMode() async {
        let transport = SettingsTransport([
            Self.hosts,
            Self.users,
            Self.hosts,
            SchedulingWritesFixtures.eventType(),
        ])
        let model = Self.hostsModel(transport)
        await model.load()
        model.routingMode = "round_robin"
        model.rotationStrategy = "priority"
        await model.save()

        let calls = SchedulingWritesFixtures.calls(transport)
        XCTAssertEqual(calls.map(\.op), [
            "eventTypes.hosts.get",
            "users.list",
            "eventTypes.hosts.put",
            "eventTypes.patch",
        ])
        XCTAssertEqual(calls[3].params["routing_mode"] as? String, "round_robin")
        XCTAssertEqual(calls[3].params["rr_strategy"] as? String, "priority")
    }

    /// ⛔ THE PUT IS A FULL REPLACEMENT, so what it carries is the whole list.
    func testEachHostIsSentWithItsRoleAndPriority() async {
        let transport = SettingsTransport([
            Self.hosts,
            Self.users,
            Self.hosts,
            SchedulingWritesFixtures.eventType(),
        ])
        let model = Self.hostsModel(transport)
        await model.load()
        model.setRole("rotation", for: "u_1")
        model.setPriority("7", for: "u_1")
        await model.save()

        let put = SchedulingWritesFixtures.calls(transport)[2]
        let sent = put.params["hosts"] as? [[String: Any]]
        XCTAssertEqual(sent?.count, 1)
        XCTAssertEqual(sent?.first?["user_id"] as? String, "u_1")
        XCTAssertEqual(sent?.first?["role"] as? String, "rotation")
        XCTAssertEqual(sent?.first?["priority"] as? Int, 7)
    }

    /// ⛔ THE REFUSAL IS ON THE SAVE, NOT ON THE REMOVE. Swapping the only host for
    /// a different one passes through zero rows, and a Remove that refused the last
    /// row would make that ordinary edit impossible.
    func testAnEmptyHostListIsRefusedAtSaveTimeAndSendsNothing() async {
        let transport = SettingsTransport([Self.hosts, Self.users])
        let model = Self.hostsModel(transport)
        await model.load()
        model.remove("u_1")
        XCTAssertTrue(model.isEmpty)
        await model.save()

        XCTAssertEqual(model.validation, "An event type needs at least one host.")
        XCTAssertEqual(SchedulingWritesFixtures.calls(transport).count, 2, "no write may have been sent")
    }

    func testAPriorityThatIsNotAWholeNumberIsRefused() async {
        let transport = SettingsTransport([Self.hosts, Self.users])
        let model = Self.hostsModel(transport)
        await model.load()
        model.setPriority("high", for: "u_1")
        await model.save()

        XCTAssertEqual(model.validation, "A host's priority has to be a whole number, 0 or more.")
        XCTAssertEqual(SchedulingWritesFixtures.calls(transport).count, 2)
    }

    /// ⛔ A REFUSED DIRECTORY READ IS NOT A FAILED SCREEN. `users.list` is
    /// admin-only at the fork; a host who may edit this table and may not list the
    /// tenancy gets the table, no add control, and no error.
    ///
    /// ⚠️ THE REFUSAL IS AN ENVELOPE RATHER THAN A 403, because `SettingsTransport`
    /// applies one status to its whole queue and the host read before it has to
    /// succeed. What is under test is that ANY refusal of the second read leaves
    /// the first one's screen intact.
    func testARefusedUserListHidesTheAddControlAndNothingElse() async {
        let transport = SettingsTransport([Self.hosts, SchedulingWritesFixtures.failure("unavailable")])
        let model = Self.hostsModel(transport)
        await model.load()

        XCTAssertFalse(model.canAddHosts)
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertNil(model.loadState.failure)
        XCTAssertFalse(model.isEmpty)
    }

    /// ⚠️ SOMEBODY ALREADY HOSTING IS NOT OFFERED AGAIN.
    func testTheAddPickerExcludesPeopleWhoAlreadyHost() async {
        let transport = SettingsTransport([Self.hosts, Self.users])
        let model = Self.hostsModel(transport)
        await model.load()

        XCTAssertEqual(model.candidates.map(\.id), ["u_2"])
    }

    /// ⛔ A FAILED PUT STOPS THE PATCH. There is no transaction across two ops, and
    /// sending the second one into a list that did not land is worse than stopping.
    func testARefusedHostListNeverReachesTheRoutingPatch() async {
        let transport = SettingsTransport([
            Self.hosts,
            Self.users,
            SchedulingWritesFixtures.failure("unavailable"),
        ])
        let model = Self.hostsModel(transport)
        await model.load()
        await model.save()

        XCTAssertEqual(SchedulingWritesFixtures.calls(transport).map(\.op).last, "eventTypes.hosts.put")
        XCTAssertEqual(model.state.failure?.message, "The booking system did not answer. Try again in a minute.")
    }

    /// ⚠️ THE ROTATION PICKER IS DRAWN ONLY FOR `round_robin`; it decides nothing
    /// on the other two modes.
    func testTheRotationStrategyIsOfferedOnlyForRoundRobin() {
        let transport = SettingsTransport([])
        let model = Self.hostsModel(transport)
        XCTAssertFalse(model.showsRotationStrategy)
        model.routingMode = "round_robin"
        XCTAssertTrue(model.showsRotationStrategy)
    }

    // MARK: - Fixtures

    private static let hosts = SchedulingWritesFixtures.items(
        #"{"user_id":"u_1","name":"Ada","email":"ada@example.com","role":"required","priority":0,"archived":false}"#
    )

    private static let users = SchedulingWritesFixtures.ok(
        """
        [{"id":"u_1","email":"ada@example.com","name":"Ada","is_admin":true,"is_owner":true,\
        "role":"admin","archived":false},\
        {"id":"u_2","email":"grace@example.com","name":"Grace","is_admin":false,"is_owner":false,\
        "role":"member","archived":false}]
        """
    )

    private static func hostsModel(_ transport: SettingsTransport) -> SchedulingEventTypeHostsModel {
        SchedulingEventTypeHostsModel(
            admin: SchedulingWritesFixtures.repository(transport),
            workspaceId: "ws_1",
            eventType: row(),
            onSaved: { _ in }
        )
    }

    private static func row() -> SchedulingEventType {
        let json = #"{"id":"et_1","slug":"phone-consultation","name":"Phone","duration_minutes":30}"#
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(SchedulingEventType.self, from: Data(json.utf8))
    }
}
