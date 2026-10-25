@testable import DistrictAIWatch
import Foundation
import XCTest

/// The long-look interfaces (3.2): the sender read off the extension's title, and the call a
/// ring alert names.
final class NotificationLongLookTests: XCTestCase {
    func testTheSenderIsTheNameAfterTheSeparatorInBothLanguages() {
        XCTAssertEqual(MessageLongLook.sender(fromTitle: "New message · Avery Contract"), "Avery Contract")
        XCTAssertEqual(MessageLongLook.sender(fromTitle: "Nouveau message · Élise Gagnon"), "Élise Gagnon")
        XCTAssertEqual(MessageLongLook.sender(fromTitle: "New message · A · B"), "A · B", "the first separator")
    }

    /// ⚠️ THE UNNAMED TITLE IS NO NAME, and the view falls back to the title as shown.
    func testNoSeparatorOrNothingAfterItIsNoName() {
        XCTAssertNil(MessageLongLook.sender(fromTitle: "New message"))
        XCTAssertNil(MessageLongLook.sender(fromTitle: "New message ·  "))
        XCTAssertNil(MessageLongLook.sender(fromTitle: ""))

        let look = MessageLongLook(title: "New message", body: "A new message arrived in your inbox.")
        XCTAssertNil(look.sender)
        XCTAssertEqual(look.title, "New message")
        XCTAssertEqual(look.body, "A new message arrived in your inbox.")
    }

    func testTheCategoriesAreTheServersOwn() {
        XCTAssertEqual(MessageLongLook.category, "district.message")
        XCTAssertEqual(CallLongLook.category, "district.incoming_call")
    }

    func testARingAlertNamesItsCall() throws {
        let look = try XCTUnwrap(CallLongLook(userInfo: [
            "type": "incoming_call", "category": "district.incoming_call", "workspaceId": "ws_1", "callId": "call_1",
            "aps": ["category": "district.incoming_call"],
        ]))
        XCTAssertEqual(look.workspaceId, "ws_1")
        XCTAssertEqual(look.callId, "call_1")
    }

    func testAnythingElseNamesNoCall() {
        XCTAssertNil(CallLongLook(userInfo: ["type": "message", "workspaceId": "ws_1", "messageId": "msg_1"]))
        XCTAssertNil(CallLongLook(userInfo: ["type": "incoming_call", "workspaceId": "ws_1"]))
        XCTAssertNil(CallLongLook(userInfo: [:]))
    }
}
