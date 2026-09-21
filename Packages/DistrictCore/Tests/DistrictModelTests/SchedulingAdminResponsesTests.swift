import DistrictModel
import Foundation
import XCTest

final class SchedulingAdminResponsesTests: XCTestCase {
    private let decoder = JSONDecoder()

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }

    /// ⛔ THE SIXTEEN NO-BODY OPS DO NOT ANSWER AN EMPTY BODY. The catalog's
    /// `NO_CONTENT` rewrites a 204 into `{ok:true}` before it leaves the route, so
    /// the wire shape is an outer flag and an inner one.
    func testNoContentDecodesTheRewrittenFlag() throws {
        XCTAssertTrue(try decode(SchedulingNoContent.self, #"{"ok":true}"#).ok)
    }

    /// ⚠️ STRICT RATHER THAN DEFAULTED. The value is constant by construction, so
    /// the field is not information about the request — it is a pin on the
    /// server's shape, and a `?? true` would let that shape change unobserved.
    func testNoContentRefusesABodyWithoutTheFlag() {
        XCTAssertThrowsError(try decode(SchedulingNoContent.self, #"{}"#))
    }

    /// ⛔ DISAMBIGUATED ON `id`, NOT ON `group_id`. A single-date row created as
    /// part of a range CARRIES a `group_id`, so the obvious test is true of most
    /// bodies and wrong for exactly the ones that matter.
    func testASingleDateOverrideDecodesAsTheRow() throws {
        let created = try decode(
            SchedulingOverrideCreated.self,
            #"""
            {"id":"ovr_1","date":"2026-12-24","is_available":false,"reason":"Closed",
             "start_time":null,"end_time":null}
            """#
        )
        guard case let .single(row) = created else {
            return XCTFail("expected the row arm, got \(created)")
        }
        XCTAssertEqual(row.id, "ovr_1")
        XCTAssertEqual(row.date, "2026-12-24")
        XCTAssertFalse(row.isAvailable)
        // ⚠️ NULLABLE, NOT ABSENT: an all-day block carries an explicit null.
        XCTAssertNil(row.startTime)
        XCTAssertNil(row.endTime)
        XCTAssertNil(row.groupId)
    }

    func testARowFromARangeStillDecodesAsTheRow() throws {
        let created = try decode(
            SchedulingOverrideCreated.self,
            #"""
            {"id":"ovr_2","date":"2026-12-25","is_available":true,"reason":"Short day",
             "start_time":"10:00","end_time":"14:00","group_id":"grp_1"}
            """#
        )
        guard case let .single(row) = created else {
            return XCTFail("expected the row arm, got \(created)")
        }
        XCTAssertEqual(row.groupId, "grp_1")
        XCTAssertEqual(row.startTime, "10:00")
        XCTAssertEqual(row.endTime, "14:00")
    }

    /// ⛔ `start` AND `end` ARE DATES HERE, NOT TIMES, and there is no `id` at all.
    func testADateRangeDecodesAsTheGroupSummary() throws {
        let created = try decode(
            SchedulingOverrideCreated.self,
            #"""
            {"group_id":"grp_1","reason":"Holiday","start":"2026-12-24","end":"2026-12-31","days":8}
            """#
        )
        guard case let .range(group) = created else {
            return XCTFail("expected the range arm, got \(created)")
        }
        XCTAssertEqual(group.groupId, "grp_1")
        XCTAssertEqual(group.reason, "Holiday")
        // ⛔ DATES, NOT TIMES. The row arm one test up carries `start_time` /
        // `end_time`; these are `start` / `end` and hold `YYYY-MM-DD`. The names
        // rhyme and a date read into a time formatter renders as a plausible wrong
        // answer rather than as an error.
        XCTAssertEqual(group.start, "2026-12-24")
        XCTAssertEqual(group.end, "2026-12-31")
        XCTAssertEqual(group.days, 8)
    }

    /// ⚠️ A BODY THAT IS NEITHER ARM FAILS ON THE **GROUP**'S ERROR, because the
    /// row is tried first with `try?` and only the second decode throws. The
    /// message names `group_id`, which reads oddly for a malformed row; that is
    /// the cost of the ordering and the ordering is the load-bearing half.
    func testABodyThatIsNeitherArmThrows() {
        XCTAssertThrowsError(try decode(SchedulingOverrideCreated.self, #"{"reason":"Closed"}"#))
    }

    /// ⛔ THE ENCODE ARM IS NOT DECORATION AND IT IS NOT TESTED BY ANY DECODE.
    /// `StrictDecodeVerifier` decodes a fixture and then RE-ENCODES it, comparing
    /// key sets — so an `encode(to:)` that wrapped the arm in a discriminator, or
    /// emitted the other arm's keys, would pass every decode test in this package
    /// and fail the contract gate, a suite away from the change that caused it. Both
    /// arms round-trip byte-identically here instead.
    ///
    /// ⚠️ COMPARED AS PARSED JSON RATHER THAN AS BYTES, because `JSONEncoder` does
    /// not promise key order and pinning one would make this fail on a Foundation
    /// change that broke nothing.
    func testBothArmsRoundTripWithoutGainingOrLosingKeys() throws {
        let bodies = [
            #"""
            {"id":"ovr_1","date":"2026-12-24","is_available":false,"reason":"Closed",
             "start_time":"09:00","end_time":"17:00","group_id":"grp_1"}
            """#,
            #"""
            {"group_id":"grp_1","reason":"Holiday","start":"2026-12-24","end":"2026-12-31","days":8}
            """#,
        ]
        for body in bodies {
            let decoded = try decode(SchedulingOverrideCreated.self, body)
            let reencoded = try JSONEncoder().encode(decoded)
            XCTAssertEqual(
                try keys(of: reencoded),
                try keys(of: Data(body.utf8)),
                "the encode arm does not mirror its decode for \(decoded)"
            )
            XCTAssertEqual(try decoder.decode(SchedulingOverrideCreated.self, from: reencoded), decoded)
        }
    }

    private func keys(of data: Data) throws -> Set<String> {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }
}
