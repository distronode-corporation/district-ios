import Foundation
import UserNotifications

/// The number on the app icon.
///
/// ⛔ IT IS ONLY EVER SET FROM A COUNT SOMEBODY ACTUALLY READ, AND THAT IS THE
/// WHOLE TYPE. A badge is a claim about the account, so zero has to mean "nothing
/// unread" and must never mean "we could not ask". There is deliberately no
/// `refresh()` here and no failure path: a caller whose read failed simply does not
/// call, which leaves the last known number on the icon rather than replacing it
/// with a lie. Adding a `set(_:)` overload that took an optional, or a `Result`,
/// would put that decision back at every call site.
///
/// ⛔ `UNUserNotificationCenter.setBadgeCount(_:)`, NEVER
/// `UIApplication.applicationIconBadgeNumber`. The second is deprecated from iOS 17,
/// which is this app's deployment floor, so it would have shipped as a deprecation
/// warning on the day it was written.
///
/// ⚠️ `@MainActor`, AND SYNCHRONOUS. All three callers are main-actor isolated
/// already (``AppDelegate``, ``PushRegistrar`` and ``InboxModel``), so the isolation
/// costs nothing; and staying synchronous keeps overload resolution away from the
/// `async throws` variant of the same selector, which would drag a `try` into every
/// call site for an error nothing can act on.
///
/// ⚠️ THE COUNT IS THE SELECTED WORKSPACE'S, NOT THE ACCOUNT'S. One icon cannot
/// carry a number per workspace, and every surface that produces one here is scoped
/// to the workspace stored in ``WorkspaceSelectionStore``. Switching workspace
/// re-badges on that workspace's next load.
@MainActor
enum UnreadBadge {
    /// Show `count` unread on the icon.
    ///
    /// ⚠️ CLAMPED AT ZERO. The numbers reaching this are derived (a sum over a list,
    /// a server field), so a subtraction that ever went wrong fails here rather than
    /// at a caller that has no better answer than this one does.
    static func set(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(max(0, count))
    }

    /// Take the badge off the icon.
    ///
    /// ⛔ THE SIGN-OUT CASE, AND IT IS NOT COSMETIC. A badge left behind after a
    /// sign-out is a count of a signed-out account's messages, shown on a handset
    /// that may by then be somebody else's.
    static func clear() {
        set(0)
    }
}
