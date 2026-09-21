import Foundation
import UserNotifications

/// The `UNUserNotificationCenter` delegate: how a notification looks in the
/// foreground, and where a tap lands.
///
/// ⛔ IT HOLDS NO STATE OF ITS OWN, DELIBERATELY. The delegate callbacks are
/// **nonisolated** — the system calls them, not the app — so any stored property
/// here would be state reachable off the main actor. Everything it learns goes
/// through ``PushTapRelay``, which is main-actor isolated, and the hop is explicit.
///
/// ⛔ AND IT DOES NOT PARSE OR ROUTE. `PushPayload` and `PushDeepLink` live in
/// `DistrictModel`, where they are testable on Linux, and `ShellView` does the
/// routing. A parser written here would live on the one tier with no test lane.
///
/// ⚠️ THE COMPLETION-HANDLER FORMS RATHER THAN THE `async` ONES. Both satisfy the
/// protocol; these are the shapes declared in the SDK, so there is no question
/// about which isolation the requirement carries — which matters on a class the
/// Linux tier cannot compile.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let relay: PushTapRelay

    init(relay: PushTapRelay) {
        self.relay = relay
        super.init()
    }

    /// ⛔ WITHOUT THIS, A NOTIFICATION ARRIVING WHILE THE APP IS OPEN IS SHOWN
    /// NOWHERE AT ALL. The default foreground behaviour is to suppress it
    /// entirely, which reads as "push is broken" during exactly the testing that
    /// is meant to prove it works.
    ///
    /// ⚠️ `.list` AS WELL AS `.banner`, so the notification is still in
    /// Notification Centre after the banner goes. A missed alert that left no
    /// trace is worse than one that was never shown.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// The user tapped a notification, or pressed one of its actions.
    ///
    /// ⚠️ THE PAYLOAD IS FLATTENED BEFORE THE HOP, NOT AFTER. `userInfo` is
    /// `[AnyHashable: Any]` and neither it nor `UNNotificationResponse` is
    /// `Sendable`; flattening first means what crosses to the main actor is a
    /// plain `[String: String]`.
    ///
    /// ⛔ THE ACTION AND ITS TYPED TEXT RIDE IN THAT SAME DICTIONARY, WHICH IS THE
    /// ONLY THING ALLOWED ACROSS ``PushTapRelay``. Two slots on the relay would be two
    /// values that can arrive out of order or be half-replaced by the next
    /// notification, and the shell reacts through `onChange`, which compares ONE value —
    /// so "which notification" and "which button" have to be one indivisible fact.
    /// ⚠️ The two keys cannot collide with the server's: the payload's own names are
    /// `type`, `category`, `workspaceId`, `messageId` and `callId`, and
    /// `PushPayload.parse` ignores anything else.
    ///
    /// ⛔ THE IDENTIFIER IS STAMPED FOR EVERY RESPONSE INCLUDING AN ORDINARY TAP, and
    /// the shell decides what an unrecognised one means. Stamping only the two known
    /// actions would make "tapped the notification" and "pressed a button this build
    /// does not know" the same input, and the second must not be treated as the first —
    /// a future action added server-side would otherwise navigate instead of doing
    /// nothing.
    ///
    /// ⚠️ THE COMPLETION HANDLER IS CALLED IMMEDIATELY, not from inside the hop, and on
    /// this path that is a rule rather than a nicety. The system uses it to know the app
    /// has finished handling the response; a handler awaiting a SEND — which is what a
    /// Reply action starts — would hold a background launch open for a network round
    /// trip, and one never called at all is a watchdog kill.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        var payload = NotificationPresenter.flatten(response.notification.request.content.userInfo)
        payload[MessageNotificationAction.identifierKey] = response.actionIdentifier
        if let typed = response as? UNTextInputNotificationResponse {
            payload[MessageNotificationAction.replyTextKey] = typed.userText
        }
        let tapRelay = relay
        Task { @MainActor in tapRelay.deliver(payload) }
        completionHandler()
    }

    /// ⛔ TOP-LEVEL `String` → `String` PAIRS AND NOTHING ELSE. An APNs payload
    /// also carries the `aps` dictionary, which is the system's, and our own keys
    /// are ids by decision — a push is readable by the OS and by any
    /// notification-listener app, so it never carries a LiveKit token or anything
    /// else that would be a credential. Dropping every non-string value is what
    /// keeps that decision from decaying into "whatever happened to be sent".
    static func flatten(_ userInfo: [AnyHashable: Any]) -> [String: String] {
        var flattened: [String: String] = [:]
        for (key, value) in userInfo {
            guard let name = key as? String, let text = value as? String else { continue }
            flattened[name] = text
        }
        return flattened
    }
}

/// A one-slot handover for the payload of a tapped notification.
///
/// ⛔ IT EXISTS BECAUSE THE DELEGATE OUTLIVES NOTHING AND THE REGISTRAR ARRIVES
/// LATE. `UNUserNotificationCenter`'s delegate has to be set during
/// `didFinishLaunchingWithOptions` or the notification that launched the app is
/// never delivered — and at that moment there is no ``PushRegistrar`` yet, because
/// the registrar attaches when the session gate reaches signed-in. A cold launch
/// FROM a notification tap therefore delivers the response before anything can
/// receive it. This buffers exactly that one case and hands it over on
/// ``adopt(registrar:)``.
///
/// ⚠️ ONE SLOT, NOT A QUEUE, AND THE NEWEST WINS. A person taps one notification
/// to go somewhere; replaying a backlog of taps would navigate them through
/// screens they did not ask for.
@MainActor
final class PushTapRelay {
    private weak var registrar: PushRegistrar?
    private var buffered: [String: String]?

    func adopt(registrar: PushRegistrar) {
        self.registrar = registrar
        guard let payload = buffered else { return }
        buffered = nil
        registrar.pendingTapPayload = payload
    }

    func deliver(_ payload: [String: String]) {
        guard let registrar else {
            buffered = payload
            return
        }
        registrar.pendingTapPayload = payload
    }
}
