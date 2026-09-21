@testable import DistrictAI
import XCTest

/// What a list row's context menu offers, from the row's own data.
final class RowContextActionsTests: XCTestCase {
    /// ⛔ AN INBOUND CALL OFFERS ITS CALLER'S NUMBER; an outbound one offers nothing, because
    /// its `from` is the workspace's own line.
    func test_IOS_ROW_MENU_01_onlyAnInboundCallerIsCopied() {
        XCTAssertEqual(
            RowContextActions.call(direction: "inbound", from: " +15555550123 "),
            [RowContextAction(title: "Copy Number", value: "+15555550123")]
        )
        XCTAssertEqual(RowContextActions.call(direction: "outbound", from: "+15555550123"), [])
        XCTAssertEqual(RowContextActions.call(direction: nil, from: "+15555550123"), [])
    }

    /// ⛔ A WITHHELD CALLER'S `from` IS A SENTENCE, NOT A NUMBER, and is never offered.
    func test_IOS_ROW_MENU_02_aWithheldCallerOffersNothing() {
        for placeholder in ["Inbound SIP Caller", "Unknown", "", "   "] {
            XCTAssertEqual(RowContextActions.call(direction: "inbound", from: placeholder), [], placeholder)
        }
        XCTAssertEqual(RowContextActions.call(direction: "inbound", from: nil), [])
    }

    /// A contact offers what it has, number first.
    func test_IOS_ROW_MENU_03_aContactOffersWhatItHas() {
        XCTAssertEqual(
            RowContextActions.contact(phone: "+15555550142", email: "ada@example.com").map(\.value),
            ["+15555550142", "ada@example.com"]
        )
        XCTAssertEqual(
            RowContextActions.contact(phone: nil, email: "ada@example.com"),
            [RowContextAction(title: "Copy Email", value: "ada@example.com")]
        )
        XCTAssertEqual(
            RowContextActions.contact(phone: "+15555550142", email: " "),
            [RowContextAction(title: "Copy Number", value: "+15555550142")]
        )
        XCTAssertEqual(RowContextActions.contact(phone: nil, email: nil), [])
    }

    /// ⚠️ A THREAD COPIES THE ADDRESS, NOT THE DISPLAY NAME AROUND IT.
    func test_IOS_ROW_MENU_04_aThreadCopiesTheBareAddress() {
        XCTAssertEqual(
            RowContextActions.thread(counterpart: "Ada Example <ada@example.com>"),
            [RowContextAction(title: "Copy Address", value: "ada@example.com")]
        )
        XCTAssertEqual(RowContextActions.thread(counterpart: "+15555550199").map(\.value), ["+15555550199"])
        XCTAssertEqual(RowContextActions.thread(counterpart: "  "), [])
        XCTAssertEqual(RowContextActions.thread(counterpart: "Ada <>"), [])
    }
}
