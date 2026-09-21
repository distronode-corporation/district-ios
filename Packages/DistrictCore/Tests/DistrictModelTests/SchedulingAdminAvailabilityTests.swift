import DistrictModel
import Foundation
import XCTest

/// The weekly rule, and the dated override it is an exception to.
///
/// ⚠️ THE OVERRIDE ROW ITSELF IS TESTED IN `SchedulingAdminResponsesTests`, beside
/// the create union. What is added here is the pair the LIST op
/// answers — a row that came from a range beside one that did not — because that
/// is the difference between "delete this day" and "delete this holiday" and the
/// two ops that spelling chooses between are different ops.
final class SchedulingAdminAvailabilityTests: XCTestCase {
    private let decoder = JSONDecoder()

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }

    // MARK: - Weekly rules

    /// ⛔ A NULL `event_type_id` MEANS "EVERY EVENT TYPE" AND IS THE COMMONEST ROW
    /// THERE IS. A screen that filtered nulls out would hide the default working
    /// week. Both polarities, because the null is the load-bearing value.
    func testARuleDecodesBothEventTypePolarities() throws {
        let scoped = try decode(
            SchedulingAvailabilityRule.self,
            #"""
            {"id":"rule_1","event_type_id":"et_1","day_of_week":1,
             "start_time":"09:00","end_time":"17:00"}
            """#
        )
        XCTAssertEqual(scoped.id, "rule_1")
        XCTAssertEqual(scoped.eventTypeId, "et_1")
        XCTAssertEqual(scoped.dayOfWeek, 1)
        XCTAssertEqual(scoped.startTime, "09:00")
        XCTAssertEqual(scoped.endTime, "17:00")

        let global = try decode(
            SchedulingAvailabilityRule.self,
            #"""
            {"id":"rule_2","event_type_id":null,"day_of_week":3,
             "start_time":"10:30","end_time":"15:00"}
            """#
        )
        XCTAssertNil(global.eventTypeId)
        XCTAssertEqual(global.dayOfWeek, 3)
    }

    /// ⛔ `event_type_id` IS `.nullable()` AND **NOT** `.optional()` IN THE CATALOG,
    /// so the key is always on the wire. A row without it is a contract break, and
    /// modelling the field as merely optional would have swallowed that silently —
    /// which matters because absent would then read as "global" for a body that has
    /// lost the field entirely.
    func testARuleWithNoEventTypeKeyAtAllIsStillDecodedAsGlobal() throws {
        // ⚠️ Swift's synthesised `Optional` decode treats absent and null alike, so
        // this passes today. It is pinned rather than asserted-against because the
        // server never sends this shape: the value here is knowing which way the
        // client leans if it ever does.
        let row = try decode(
            SchedulingAvailabilityRule.self,
            #"{"id":"rule_3","day_of_week":0,"start_time":"08:00","end_time":"12:00"}"#
        )
        XCTAssertNil(row.eventTypeId)
        // ⚠️ 0 IS SUNDAY, not Monday, and not `Calendar`'s 1...7 `weekday`.
        XCTAssertEqual(row.dayOfWeek, 0)
    }

    /// ⛔ THE TIMES ARE ZERO-PADDED `HH:MM` STRINGS AND NOTHING PARSES THEM HERE.
    /// The fork refuses `9:00`, so the padding is the contract; a client that
    /// re-formatted them through a `DateFormatter` would drop the leading zero on
    /// some locales and get a 400 on the way back in.
    func testTheTimesStayStringsAndKeepTheirPadding() throws {
        let row = try decode(
            SchedulingAvailabilityRule.self,
            #"""
            {"id":"rule_4","event_type_id":null,"day_of_week":6,
             "start_time":"08:05","end_time":"09:00"}
            """#
        )
        XCTAssertEqual(row.startTime, "08:05")
        XCTAssertEqual(row.endTime, "09:00")
    }

    // MARK: - Dated overrides, as the LIST op answers them

    /// ⛔ THE ROW THAT CAME FROM A RANGE IS THE ONE THAT MATTERS. `group_id` is what
    /// makes `availability.overrides.deleteGroup` addressable from a day the user
    /// tapped, and deleting that day alone leaves the rest of the holiday in place.
    func testAnOverrideFromARangeCarriesItsGroup() throws {
        let grouped = try decode(
            SchedulingAvailabilityOverride.self,
            #"""
            {"id":"ovr_1","date":"2026-09-24","is_available":true,"reason":"custom_hours",
             "start_time":"12:00","end_time":"16:00","group_id":"grp_1"}
            """#
        )
        XCTAssertEqual(grouped.groupId, "grp_1")
        XCTAssertTrue(grouped.isAvailable)
        XCTAssertEqual(grouped.reason, "custom_hours")
        XCTAssertEqual(grouped.startTime, "12:00")
        XCTAssertEqual(grouped.endTime, "16:00")
    }

    /// ⚠️ AN ALL-DAY BLOCK NULLS BOTH TIMES AND OMITS THE GROUP. Three optionals,
    /// two of them explicit nulls and one an absent key, on one row.
    func testAnAllDayOverrideNullsItsTimesAndHasNoGroup() throws {
        let block = try decode(
            SchedulingAvailabilityOverride.self,
            #"""
            {"id":"ovr_2","date":"2026-09-25","is_available":false,"reason":"day_off",
             "start_time":null,"end_time":null}
            """#
        )
        XCTAssertFalse(block.isAvailable)
        XCTAssertNil(block.startTime)
        XCTAssertNil(block.endTime)
        XCTAssertNil(block.groupId)
        XCTAssertEqual(block.date, "2026-09-25")
    }
}
