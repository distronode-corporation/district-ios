import WatchKit

/// The watch app's background tasks: the WatchConnectivity wake that delivers a snapshot, and
/// the background refresh that keeps the unread complication fresh (3.2).
///
/// ⛔ A DELEGATE, NOT `.backgroundTask` MODIFIERS, AND NOT BY TASTE. `WKApplication`'s
/// `scheduleBackgroundRefresh` REQUIRES a `WKApplicationDelegate` that implements
/// `handle(_:)`: without one, watchOS kills the app on the first schedule ("Critical failure.
/// Simulating crash ... requires that your WKApplicationDelegate (null) implement
/// handleBackgroundTasks:", seen in the watch test host on the simulator). Once the delegate
/// handles tasks it handles them all, so the WatchConnectivity wake that 3.1.0 took through
/// `.backgroundTask(.watchConnectivity)` is handled here too, the same way.
///
/// ⛔ EVERY TASK IS COMPLETED, on every path: an uncompleted task costs the app its
/// background budget. ⚠️ A task that arrives without ``work`` (the debug preview screens) is
/// completed at once.
///
/// ⛔ THE CHAIN STARTS IN ``applicationDidFinishLaunching()``, NOT IN THE APP'S `init`: the
/// adaptor installs this delegate only after `init`, and a refresh scheduled before that
/// trips the same simulated crash.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    /// The store and the link, set once by ``DistrictAIWatchApp`` in its `init`.
    struct Work {
        let store: WatchStore
        let link: LivePhoneLink
    }

    static var work: Work?

    func applicationDidFinishLaunching() {
        Self.work?.store.scheduleBackgroundRefresh()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            guard let work = Self.work else {
                task.setTaskCompletedWithSnapshot(false)
                continue
            }
            switch task {
            case is WKApplicationRefreshBackgroundTask:
                // See ``WatchStore/refreshInBackground()``. The phone's answer is an
                // application context, waited for like the wake below.
                Task {
                    await work.store.refreshInBackground()
                    await work.link.waitForPendingContent()
                    task.setTaskCompletedWithSnapshot(false)
                }
            case is WKWatchConnectivityRefreshBackgroundTask:
                // ⚠️ A SNAPSHOT CAN ARRIVE WHILE THE APP IS NOT RUNNING. The session
                // (activated in the app's `init`) delivers the context, and the store updates
                // the complication before the task completes.
                Task {
                    await work.link.waitForPendingContent()
                    task.setTaskCompletedWithSnapshot(false)
                }
            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
