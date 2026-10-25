@testable import DistrictAI
import Foundation
import XCTest

/// ``WireDate`` — the one display helper for the API's ISO-8601 instants.
final class WireDateTests: XCTestCase {
    /// ⚠️ AN UNPARSEABLE INSTANT IS SHOWN AS IT CAME, never as a blank line.
    func testAnUnparseableInstantFallsBackToTheRawString() {
        XCTAssertEqual(WireDate.display("soon"), "soon")
        XCTAssertEqual(WireDate.display(""), "")
    }

    /// ⚠️ BOTH WIRE SHAPES RENDER, AND RENDER THE SAME MINUTE.
    func testFractionalAndPlainStampsRenderAlike() {
        let zone = TimeZone(identifier: "UTC")
        let plain = WireDate.display("2026-09-12T14:30:00Z", in: zone)
        XCTAssertNotEqual(plain, "2026-09-12T14:30:00Z")
        XCTAssertEqual(WireDate.display("2026-09-12T14:30:00.123Z", in: zone), plain)
    }

    /// ⛔ THE ZONE IS HONOURED: one instant reads as two different days in Toronto and
    /// Tokyo, which is what the reschedule sheet's slot labels depend on.
    func testTheZoneIsHonoured() {
        let stamp = "2026-10-04T16:00:00Z"
        let toronto = WireDate.display(stamp, in: TimeZone(identifier: "America/Toronto"))
        let tokyo = WireDate.display(stamp, in: TimeZone(identifier: "Asia/Tokyo"))
        XCTAssertNotEqual(toronto, tokyo)
        XCTAssertEqual(
            toronto,
            WireDate.display("2026-10-04T12:00:00-04:00", in: TimeZone(identifier: "America/Toronto"))
        )
    }

    /// ⚠️ A FRENCH CLOCK NEVER BREAKS AROUND ITS `h` (3.2.0 visual QA: the call detail at
    /// accessibility XL ended a line on `16` and began the next on `h 13`). The date's own
    /// spaces still wrap.
    func testTheFrenchClockIsHeldOnOneLine() {
        XCTAssertEqual(WireDate.unbroken("23 sept. 2026, 16 h 13"), "23 sept. 2026, 16\u{00A0}h\u{00A0}13")
        XCTAssertEqual(WireDate.unbroken("1er oct. 2026, 9 h"), "1er oct. 2026, 9\u{00A0}h")
        XCTAssertEqual(WireDate.unbroken("12 sept. 2026, 0 h 05"), "12 sept. 2026, 0\u{00A0}h\u{00A0}05")
        XCTAssertEqual(WireDate.unbroken("Sep 12, 2026 at 2:30 PM"), "Sep 12, 2026 at 2:30 PM")
    }
}
