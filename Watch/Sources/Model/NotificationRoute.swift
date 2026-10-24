import Foundation
import UserNotifications

/// Where a tapped notification asks to go.
///
/// ⛔ THE SERVER'S PAYLOAD, READ BY THE PHONE'S RULES, NOT A SHAPE OF ITS OWN. The watch
/// links no DistrictCore, so this is a copy of `PushPayload.parse` (DistrictModel) for the
/// one case the watch acts on: the same four key names, verbatim, the type matched
/// exactly, values trimmed and a blank treated as absent. A message push carries
/// `workspaceId` and `messageId` and, by decision, NO thread key (see `PushEvent.message`):
/// the phone turns the message into its thread (``WatchAction/resolveMessage(workspaceId:messageId:)``).
///
/// ⚠️ ANYTHING ELSE IS NIL AND MOVES NOTHING. An `incoming_call` is CallKit's on the phone,
/// and a type this build does not know is the server being ahead of it.
enum WatchNotificationRoute: Equatable, Sendable {
    case message(workspaceId: String, messageId: String)

    static let keyType = "type"
    static let keyWorkspaceId = "workspaceId"
    static let keyMessageId = "messageId"
    static let typeMessage = "message"

    static func parse(_ payload: [String: String]) -> WatchNotificationRoute? {
        guard let workspaceId = value(payload, keyWorkspaceId),
              value(payload, keyType) == typeMessage,
              let messageId = value(payload, keyMessageId)
        else { return nil }
        return .message(workspaceId: workspaceId, messageId: messageId)
    }

    /// ⛔ TOP-LEVEL `String` → `String` PAIRS ONLY, as the phone's `NotificationPresenter`
    /// flattens: `aps` is the system's, and a non-string value is never coerced.
    static func flatten(_ userInfo: [AnyHashable: Any]) -> [String: String] {
        var flattened: [String: String] = [:]
        for (key, value) in userInfo {
            guard let name = key as? String, let text = value as? String else { continue }
            flattened[name] = text
        }
        return flattened
    }

    private static func value(_ payload: [String: String], _ key: String) -> String? {
        let trimmed = payload[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The `UNUserNotificationCenter` delegate on the watch: where a tap lands.
///
/// ⛔ NOT MAIN-ACTOR ISOLATED, AND EVERYTHING IT HANDS ON IS `@Sendable`, BECAUSE THE SYSTEM
/// CALLS IT ON ITS OWN QUEUE. A closure written inside a `@MainActor` type is isolated to
/// the main actor, and Swift 6 checks that isolation when an Objective-C API calls it: off
/// the main thread the check traps (SIGILL in `dispatch_assert_queue`), the PR #79 crash in
/// ``LivePhoneLink``. So the payload is flattened HERE, to a `Sendable` `[String: String]`,
/// and the one hop to the main actor is explicit, inside ``onTap``'s owner.
///
/// ⚠️ THE COMPLETION-HANDLER FORMS, as on the phone (`NotificationPresenter`): the shapes
/// declared in the SDK, with no question about which isolation the requirement carries.
///
/// ⛔ ONLY A TAP ROUTES. Dismiss, and any button (a mirrored phone notification carries the
/// phone's Reply and Mark read), is not "go there", and a button this build does not know
/// must never navigate. This app registers no categories and no actions of its own.
final class WatchNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    /// ⚠️ SET ONCE, IN `init`, which is why it needs no lock.
    private let onTap: @Sendable ([String: String]) -> Void

    init(onTap: @escaping @Sendable ([String: String]) -> Void) {
        self.onTap = onTap
        super.init()
    }

    /// ⚠️ `.list` AS WELL AS `.banner`, as on the phone: without this method a notification
    /// arriving while the watch app is open is shown nowhere at all.
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        receive(actionIdentifier: response.actionIdentifier, userInfo: response.notification.request.content.userInfo)
        completionHandler()
    }

    /// The response, as plain values: what the tests drive off the main thread, since
    /// `UNNotificationResponse` has no public initializer.
    func receive(actionIdentifier: String, userInfo: [AnyHashable: Any]) {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        onTap(WatchNotificationRoute.flatten(userInfo))
    }

    /// The app's delegate: every tap to ``WatchStore/open(_:)``.
    ///
    /// ⛔ `@Sendable`, SO NOT ISOLATED TO THE MAIN ACTOR this is built on: the system calls
    /// it on its own queue, and the hop is the `Task`.
    @MainActor
    static func routing(to store: WatchStore) -> WatchNotificationDelegate {
        WatchNotificationDelegate { @Sendable payload in
            Task { @MainActor in await store.open(payload) }
        }
    }
}
