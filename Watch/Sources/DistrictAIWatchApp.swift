import SwiftUI
import UserNotifications
import WatchKit

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
        // ⛔ IN `init` TOO: Siri and Shortcuts run an intent in a background launch with no
        // scene (3.2), and a long-look notification needs the store. See ``WatchProcess``.
        WatchProcess.intents = WatchIntentRunner(store: store, link: link)
        WatchProcess.store = store
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
        // ⚠️ THE LONG LOOKS (3.2): a message names its sender, and a call shows its card. The
        // buttons under each are the iPhone's own category actions (Reply, Mark read), drawn by
        // the system; these scenes add none.
        WKNotificationScene(controller: MessageNotificationController.self, category: MessageLongLook.category)
        WKNotificationScene(controller: CallNotificationController.self, category: CallLongLook.category)
    }
}
