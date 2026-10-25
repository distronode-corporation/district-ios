import SwiftUI
import UserNotifications
import WatchKit

/// The long look of a message alert: who it is from, and what the alert says.
///
/// ⚠️ THE NAME IS `.privacySensitive()`, as the unread count is: a raised wrist is read by
/// whoever is beside you, and a locked watch redacts it.
struct MessageNotificationView: View {
    let look: MessageLongLook

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(WatchCopy.notificationMessage, systemImage: "message.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(look.sender ?? look.title)
                .font(.headline)
                .privacySensitive()
            Text(look.body)
                .font(.footnote)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The long look of a call alert: the call's card, read from the phone as Recent calls reads it.
///
/// ⚠️ THE ALERT'S OWN TEXT WHEN THERE IS NO CARD TO SHOW: a payload naming no call, or a store
/// the system did not give this process (``WatchProcess``).
struct CallNotificationView: View {
    let look: CallLongLook?
    let alertTitle: String
    let alertBody: String

    var body: some View {
        if let look, let store = WatchProcess.store {
            CallCardView(store: store, workspaceId: look.workspaceId, callId: look.callId, seed: nil)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(alertTitle)
                    .font(.headline)
                Text(alertBody)
                    .font(.footnote)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// `district.message`'s long look.
///
/// ⚠️ `didReceive` RUNS BEFORE THE SYSTEM FIRST READS `body`, so the stored values are what it
/// draws; `WKUserNotificationHostingController` offers no body update to ask for.
final class MessageNotificationController: WKUserNotificationHostingController<MessageNotificationView> {
    private var look = MessageLongLook(title: "", body: "")

    override var body: MessageNotificationView {
        MessageNotificationView(look: look)
    }

    override func didReceive(_ notification: UNNotification) {
        look = MessageLongLook(title: notification.request.content.title, body: notification.request.content.body)
    }
}

/// `district.incoming_call`'s long look.
final class CallNotificationController: WKUserNotificationHostingController<CallNotificationView> {
    private var look: CallLongLook?
    private var alertTitle = ""
    private var alertBody = ""

    override var body: CallNotificationView {
        CallNotificationView(look: look, alertTitle: alertTitle, alertBody: alertBody)
    }

    override func didReceive(_ notification: UNNotification) {
        let content = notification.request.content
        look = CallLongLook(userInfo: content.userInfo)
        alertTitle = content.title
        alertBody = content.body
    }
}
