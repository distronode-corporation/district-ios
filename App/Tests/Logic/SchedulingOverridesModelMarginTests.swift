@testable import DistrictAI
import DistrictData
import DistrictModel
import Foundation
import XCTest

/// ``SchedulingAvailabilityOverridesModel``'s add sheet and its writes, past what
/// `SchedulingWritesAvailabilityTests` holds: a refused read, the add sheet's validation and
/// cancel, a create that re-reads and reports, a refused create that keeps the sheet, a single
/// day's delete, a refused delete, a re-read that fails after a write, and the notices.
@MainActor
final class SchedulingOverridesModelMarginTests: XCTestCase {
    private static let single = """
    {"id":"o_3","date":"2026-09-20","is_available":false,"reason":"day_off",\
    "start_time":null,"end_time":null,"group_id":null}
    """

    private static let singleList = SchedulingWritesFixtures.items(single)

    private func model(
        _ transport: SettingsTransport,
        saved: @escaping ([SchedulingAvailabilityOverride]) -> Void = { _ in }
    ) -> SchedulingAvailabilityOverridesModel {
        SchedulingAvailabilityOverridesModel(
            admin: SchedulingWritesFixtures.repository(transport),
            workspaceId: "ws_1",
            today: "2026-09-12",
            onSaved: saved
        )
    }

    func testARefusedReadIsAFailedLoad() async {
        let transport = SettingsTransport([SchedulingWritesFixtures.failure("scheduling_unavailable")])
        let model = model(transport)
        await model.load()
        guard case .failed = model.loadState else { return XCTFail("expected a failed load, got \(model.loadState)") }
        XCTAssertEqual(model.rows.count, 0)
    }

    func testAnEmptyListLoadsNoRows() async {
        let transport = SettingsTransport([SchedulingWritesFixtures.items("")])
        let model = model(transport)
        await model.load()
        guard case .idle = model.loadState else { return XCTFail("expected idle, got \(model.loadState)") }
        XCTAssertEqual(model.rows.count, 0)
    }

    /// An invalid form is refused before any request, and the sentence clears on cancel.
    func testAnInvalidFormIsRefusedBeforeAnyRequest() async {
        let transport = SettingsTransport([Self.singleList])
        let model = model(transport)
        await model.load()
        model.beginAdd()
        await model.submit()
        XCTAssertEqual(model.validation, "Pick a date.")
        XCTAssertNotNil(model.adding)
        XCTAssertEqual(transport.requests.count, 1, "only the read")
        model.cancelAdd()
        XCTAssertNil(model.adding)
        XCTAssertNil(model.validation)
    }

    /// A submit with no sheet open, and an edit with no sheet open, do nothing.
    func testNoSheetNoWrite() async {
        let transport = SettingsTransport([Self.singleList])
        let model = model(transport)
        await model.load()
        model.updateAdding { $0.date = "2026-09-21" }
        XCTAssertNil(model.adding)
        await model.submit()
        await model.delete()
        XCTAssertEqual(transport.requests.count, 1)
        guard case .idle = model.state else { return XCTFail("expected idle, got \(model.state)") }
    }

    /// A create sends the form, closes the sheet, re-reads and hands the new list up.
    func testACreateRereadsAndReportsTheNewList() async {
        let transport = SettingsTransport([
            SchedulingWritesFixtures.items(""),
            SchedulingWritesFixtures.ok(Self.single),
            Self.singleList,
        ])
        var handed: [SchedulingAvailabilityOverride]?
        let model = model(transport) { handed = $0 }
        await model.load()
        model.beginAdd()
        model.updateAdding { $0.date = "2026-09-20" }
        await model.submit()

        let call = SchedulingWritesFixtures.calls(transport)[1]
        XCTAssertEqual(call.op, "availability.overrides.create")
        XCTAssertEqual(call.params["date"] as? String, "2026-09-20")
        guard case .done = model.state else { return XCTFail("expected done, got \(model.state)") }
        XCTAssertNil(model.adding)
        XCTAssertNil(model.validation)
        XCTAssertEqual(model.rows.map(\.target), ["o_3"])
        XCTAssertEqual(handed?.count, 1)
        model.dismissNotice()
        guard case .idle = model.state else { return XCTFail("expected idle, got \(model.state)") }
    }

    /// A refused create keeps the sheet open with what was typed.
    func testARefusedCreateKeepsTheSheet() async {
        let transport = SettingsTransport([
            SchedulingWritesFixtures.items(""),
            SchedulingWritesFixtures.failure("conflict"),
        ])
        var handed = false
        let model = model(transport) { _ in handed = true }
        await model.load()
        model.beginAdd()
        model.updateAdding { $0.date = "2026-09-20" }
        await model.submit()
        guard case .failed = model.state else { return XCTFail("expected failed, got \(model.state)") }
        XCTAssertEqual(model.adding?.date, "2026-09-20")
        XCTAssertFalse(handed)
        XCTAssertEqual(transport.requests.count, 2, "no re-read after a refusal")
    }

    /// ⛔ A single day is deleted by its own id with the single op.
    func testASingleDayIsDeletedByItsId() async {
        let transport = SettingsTransport([
            Self.singleList,
            SchedulingWritesFixtures.noContent,
            SchedulingWritesFixtures.items(""),
        ])
        let model = model(transport)
        await model.load()
        guard let row = model.rows.first else { return XCTFail("the fixture has one row") }
        XCTAssertEqual(model.deleteBody(for: row), SchedulingWriteCopy.overrideDeleteSingleBody)
        model.beginDelete(row)
        XCTAssertEqual(model.confirmingDelete?.target, "o_3")
        await model.delete()

        let call = SchedulingWritesFixtures.calls(transport)[1]
        XCTAssertEqual(call.op, "availability.overrides.delete")
        XCTAssertEqual(call.params["id"] as? String, "o_3")
        XCTAssertNil(model.confirmingDelete)
        guard case .done = model.state else { return XCTFail("expected done, got \(model.state)") }
        XCTAssertEqual(model.rows.count, 0)
    }

    func testCancellingADeleteSendsNothing() async {
        let transport = SettingsTransport([Self.singleList])
        let model = model(transport)
        await model.load()
        guard let row = model.rows.first else { return XCTFail("the fixture has one row") }
        model.beginDelete(row)
        model.cancelDelete()
        XCTAssertNil(model.confirmingDelete)
        await model.delete()
        XCTAssertEqual(transport.requests.count, 1)
    }

    /// A refused delete keeps the row and says why.
    func testARefusedDeleteKeepsTheRow() async {
        let transport = SettingsTransport([Self.singleList, SchedulingWritesFixtures.failure("scheduling_unavailable")])
        let model = model(transport)
        await model.load()
        guard let row = model.rows.first else { return XCTFail("the fixture has one row") }
        model.beginDelete(row)
        await model.delete()
        guard case .failed = model.state else { return XCTFail("expected failed, got \(model.state)") }
        XCTAssertEqual(model.rows.map(\.target), ["o_3"])
    }

    /// A write that landed but whose re-read failed reports the write and fails the load,
    /// without handing a list up.
    func testAFailedRereadAfterADeleteFailsTheLoad() async {
        let transport = SettingsTransport([
            Self.singleList,
            SchedulingWritesFixtures.noContent,
            SchedulingWritesFixtures.failure("scheduling_unavailable"),
        ])
        var handed = false
        let model = model(transport) { _ in handed = true }
        await model.load()
        guard let row = model.rows.first else { return XCTFail("the fixture has one row") }
        model.beginDelete(row)
        await model.delete()
        guard case .done = model.state else { return XCTFail("expected done, got \(model.state)") }
        guard case .failed = model.loadState else { return XCTFail("expected a failed load, got \(model.loadState)") }
        XCTAssertFalse(handed)
    }
}
