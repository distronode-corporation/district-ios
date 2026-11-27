@testable import DistrictAI
import UserNotifications
import XCTest

/// Which notification responses the shade's own buttons produced, so the delegate routes them to
/// the relay instead of opening the app. ⚠️ Registering and posting go through the system
/// notification center and are not exercised here.
final class NotificationActionPlatformMarginTests: XCTestCase {
    func testEveryShadeButtonIsAShadeAction() {
        for identifier in [
            MessageNotificationAction.reply,
            MessageNotificationAction.markRead,
            DeclineSteerNotification.typed,
            DeclineSteerNotification.callBackToday,
            DeclineSteerNotification.askWhatAbout,
        ] {
            XCTAssertTrue(MessageNotificationAction.isShadeAction(identifier), identifier)
        }
    }

    /// ⛔ A tap on the notification itself, a dismissal, a category name and near misses open
    /// the app or do nothing; none of them is answered as a button.
    func testTheSystemsOwnResponsesAndNearMissesAreNot() {
        for identifier in [
            UNNotificationDefaultActionIdentifier,
            UNNotificationDismissActionIdentifier,
            DistrictNotificationCategory.message,
            DeclineSteerNotification.category,
            "",
            " ",
            MessageNotificationAction.reply.uppercased(),
            MessageNotificationAction.reply + " ",
            " " + MessageNotificationAction.markRead,
            "district.message",
            "district.message.reply.extra",
            "district.declined_steer.",
            MessageNotificationAction.identifierKey,
            MessageNotificationAction.replyTextKey,
        ] {
            XCTAssertFalse(MessageNotificationAction.isShadeAction(identifier), "\"\(identifier)\"")
        }
    }

    /// The identifiers the relay and the shade agree on are all distinct, so no button can be
    /// mistaken for another, and the payload keys collide with none of them.
    func testIdentifiersAndKeysAreDistinct() {
        let all = [
            DistrictNotificationCategory.message,
            MessageNotificationAction.reply,
            MessageNotificationAction.markRead,
            MessageNotificationAction.identifierKey,
            MessageNotificationAction.replyTextKey,
            DeclineSteerNotification.category,
            DeclineSteerNotification.typed,
            DeclineSteerNotification.callBackToday,
            DeclineSteerNotification.askWhatAbout,
        ]
        XCTAssertEqual(Set(all).count, all.count)
        XCTAssertEqual(DistrictNotificationCategory.message, "district.message")
        XCTAssertTrue(MessageNotificationAction.reply.hasPrefix(DistrictNotificationCategory.message + "."))
        XCTAssertTrue(MessageNotificationAction.markRead.hasPrefix(DistrictNotificationCategory.message + "."))
    }
}
