import DistrictModel
import Foundation
import UserNotifications

/// Takes a finished ring's `incoming_call` alert out of Notification Centre.
///
/// ⚠️ THE DECISION IS ``RingCancel/alertIdentifiers(in:)``, WHICH HAS TESTS. This is only
/// the two `UNUserNotificationCenter` calls around it, which a unit test cannot drive.
///
/// ⚠️ NONISOLATED ON PURPOSE. `deliveredNotifications()` hands back `UNNotification`s,
/// which are not `Sendable`; reading them where they arrive and returning a count keeps
/// them off the main actor entirely, and only the `Sendable` cancel crosses in.
enum DeliveredRingAlerts {
    /// Remove every delivered alert that announced `cancel`'s call. Returns how many.
    static func remove(for cancel: RingCancel) async -> Int {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications().map { notification in
            (
                identifier: notification.request.identifier,
                payload: NotificationPresenter.flatten(notification.request.content.userInfo)
            )
        }
        let identifiers = cancel.alertIdentifiers(in: delivered)
        guard !identifiers.isEmpty else { return 0 }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        return identifiers.count
    }
}
