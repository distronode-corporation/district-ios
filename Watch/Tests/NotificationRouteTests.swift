@testable import DistrictAIWatch
import UserNotifications
import XCTest

/// A tapped notification's payload, read by the phone's rules (`PushPayload.parse`).
final class NotificationRouteTests: XCTestCase {
    /// ⚠️ THE SHAPE THE SERVER SENDS: `aps` beside the server's string keys.
    func testAMessagePushIsAMessageRoute() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Marie Tremblay", "body": "New message"], "category": "district.message"],
            "type": "message",
            "category": "district.message",
            "workspaceId": "ws_1",
            "messageId": "msg_1",
        ]

        let route = WatchNotificationRoute.parse(WatchNotificationRoute.flatten(userInfo))

        XCTAssertEqual(route, .message(workspaceId: "ws_1", messageId: "msg_1"))
    }

    /// ⛔ ANOTHER TYPE, OR A TYPE MATCHED ONLY LOOSELY, IS NOT A MESSAGE.
    func testOtherTypesAreNoRoute() {
        for type in ["incoming_call", "Message", "message_v2", ""] {
            let payload = ["type": type, "workspaceId": "ws_1", "messageId": "msg_1", "callId": "call_1"]
            XCTAssertNil(WatchNotificationRoute.parse(payload), type)
        }
    }

    /// ⛔ A MISSING OR BLANK ID IS A DROP, NEVER A DEFAULT; values are trimmed.
    func testMissingOrBlankKeysAreNoRoute() {
        XCTAssertNil(WatchNotificationRoute.parse(["type": "message", "workspaceId": "ws_1"]))
        XCTAssertNil(WatchNotificationRoute.parse(["type": "message", "messageId": "msg_1"]))
        XCTAssertNil(WatchNotificationRoute.parse(["workspaceId": "ws_1", "messageId": "msg_1"]))
        XCTAssertNil(WatchNotificationRoute.parse(["type": "message", "workspaceId": "  ", "messageId": "msg_1"]))
        XCTAssertEqual(
            WatchNotificationRoute.parse(["type": " message ", "workspaceId": " ws_1", "messageId": "msg_1\n"]),
            .message(workspaceId: "ws_1", messageId: "msg_1")
        )
    }

    /// ⛔ A NON-STRING VALUE IS DROPPED, NOT COERCED: `1` is not `"1"`.
    func testNonStringValuesAreDropped() {
        let flattened = WatchNotificationRoute.flatten(["type": "message", "workspaceId": "ws_1", "messageId": 1])

        XCTAssertNil(flattened["messageId"])
        XCTAssertNil(WatchNotificationRoute.parse(flattened))
    }
}

/// The delegate the system calls. Its off-main path is in ``WatchStoreTests``, which has
/// the store it hands to.
final class WatchNotificationDelegateTests: XCTestCase {
    /// ⛔ ONLY A TAP ROUTES: dismiss, and a mirrored notification's Reply or Mark read, do not.
    func testOnlyTheDefaultActionRoutes() {
        let routed = LockedCount()
        let delegate = WatchNotificationDelegate { @Sendable _ in routed.increment() }
        let payload: [AnyHashable: Any] = ["type": "message", "workspaceId": "ws_1", "messageId": "msg_1"]

        for identifier in [
            UNNotificationDismissActionIdentifier,
            "district.message.reply",
            "district.message.mark-read",
        ] {
            delegate.receive(actionIdentifier: identifier, userInfo: payload)
        }
        XCTAssertEqual(routed.value, 0)

        delegate.receive(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: payload)
        XCTAssertEqual(routed.value, 1)
    }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
