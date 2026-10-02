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
}
