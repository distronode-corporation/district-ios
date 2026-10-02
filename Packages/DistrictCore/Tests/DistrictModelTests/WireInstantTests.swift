import DistrictModel
import Foundation
import XCTest

/// ``WireInstant`` — the one ISO-8601 parser the app and the package share.
final class WireInstantTests: XCTestCase {
    func testParsesAStampWithFractionalSeconds() throws {
        let date = try XCTUnwrap(WireInstant.parse("2026-09-12T14:30:00.123Z"))
        XCTAssertEqual(date.timeIntervalSince1970, 1_789_223_400.123, accuracy: 0.0005)
    }

    /// ⚠️ THE PAIR THAT NEEDS TWO STYLES. A parser configured for fractional seconds
    /// refuses their absence and the reverse, and the server sends both shapes.
    func testParsesAStampWithoutFractionalSeconds() {
        XCTAssertEqual(WireInstant.parse("2026-09-12T14:30:00Z")?.timeIntervalSince1970, 1_789_223_400)
    }

    /// ⚠️ AN OFFSET IS HONOURED, with or without fractional seconds.
    func testHonoursAnOffset() {
        XCTAssertEqual(WireInstant.parse("2026-09-12T16:30:00+02:00")?.timeIntervalSince1970, 1_789_223_400)
        XCTAssertEqual(WireInstant.parse("2026-09-12T10:30:00.000-04:00")?.timeIntervalSince1970, 1_789_223_400)
    }

    /// ⛔ nil IS "THIS IS NOT A TIME" AND EVERY CALLER RENDERS A WORD FOR IT rather than
    /// falling back to now, which would put today's date on a corrupt row.
    func testRefusesSomethingThatIsNotAStamp() {
        XCTAssertNil(WireInstant.parse("not a date"))
        XCTAssertNil(WireInstant.parse(""))
        XCTAssertNil(WireInstant.parse("2026-09-12"))
    }
}
