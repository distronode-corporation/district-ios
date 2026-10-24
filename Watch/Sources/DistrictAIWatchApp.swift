import SwiftUI
import UserNotifications

/// The Apple Watch companion app.
///
/// ⛔ A COMPANION, NOT AN INDEPENDENT APP (`WKRunsIndependentlyOfCompanionApp` is false).
/// It holds no credential and makes no network call: it shows what the iPhone sends and asks
/// the iPhone to write. See ``WatchStore`` and, on the phone, `WatchBridgeService`.
///
/// ⛔ ONE STORE PER PROCESS, BUILT HERE, so the session's delegate and the screen read one
/// model.
@main
struct DistrictAIWatchApp: App {
    @State private var store: WatchStore
    private let link: LivePhoneLink
    /// ⚠️ HELD HERE: `UNUserNotificationCenter.delegate` is weak.
    private let notifications: WatchNotificationDelegate

    init() {
        let link = LivePhoneLink()
        self.link = link
        let store = WatchStore(
            link: link,
            persistence: GroupSnapshotStore(),
            complication: WidgetComplicationPublisher()
        )
        _store = State(initialValue: store)
        // ⛔ IN `init`, BEFORE LAUNCH FINISHES, or the tap that launched the app is never
        // delivered. Called on the system's own queue: see ``WatchNotificationDelegate``.
        let notifications = WatchNotificationDelegate.routing(to: store)
        self.notifications = notifications
        UNUserNotificationCenter.current().delegate = notifications
        #if DEBUG
            if WatchPreviewSeam.apply(to: store) {
                return
            }
        #endif
        store.start()
    }

    var body: some Scene {
        // ⚠️ THE LINK, NOT `self`, GOES INTO THE BACKGROUND TASK: the closure is `@Sendable`.
        let link = link
        WindowGroup {
            #if DEBUG
                if let screen = WatchPreviewSeam.screen {
                    WatchPreviewSeam.view(for: screen, store: store)
                } else {
                    WatchRootView(store: store)
                }
            #else
                WatchRootView(store: store)
            #endif
        }
        // ⚠️ A SNAPSHOT CAN ARRIVE WHILE THE APP IS NOT RUNNING. The system wakes it for
        // this task; the session (activated in `init`) delivers the context, and the store
        // updates the complication before the task returns.
        .backgroundTask(.watchConnectivity) {
            await link.waitForPendingContent()
        }
    }
}
