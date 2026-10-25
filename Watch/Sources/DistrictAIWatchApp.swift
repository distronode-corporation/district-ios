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
    /// ⛔ THE BACKGROUND TASKS. See ``WatchAppDelegate`` for why it is a delegate.
    @WKApplicationDelegateAdaptor private var delegate: WatchAppDelegate
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
            complication: WidgetComplicationPublisher(),
            backgroundRefresh: WatchBackgroundRefresh()
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
        // ⚠️ AFTER THE PREVIEW SEAM: a preview runs no background task and schedules none.
        WatchAppDelegate.work = WatchAppDelegate.Work(store: store, link: link)
        store.start()
    }

    var body: some Scene {
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
    }
}
