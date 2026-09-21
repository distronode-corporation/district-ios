import Foundation
import PushKit
import UIKit
import UserNotifications

/// The UIKit application delegate, which exists for exactly two things SwiftUI has
/// no equivalent of: the APNs device-token callbacks, and setting the
/// `UNUserNotificationCenter` delegate early enough to receive the notification
/// that launched the app.
///
/// ⛔ IT BUILDS NOTHING AND OWNS NO OBJECT GRAPH. There is one ``AppContainer`` per
/// process and `DistrictApp` holds it; a container constructed here would be a
/// second ``TokenRefreshCoordinator``, which is the failure mode `AppContainer`'s
/// own ⛔ describes. What reaches this class is a
/// ``PushRegistrar``, handed over by `DistrictApp.body` through the
/// `@UIApplicationDelegateAdaptor`'s own instance.
///
/// ⛔ NEVER HANDED OVER BY THE REGISTRAR ITSELF THROUGH
/// `UIApplication.shared.delegate as? AppDelegate` — THAT CAST FAILS ON DEVICE.
/// The adopt below would never run, ``registrar`` would stay nil, and every device
/// token this class received would be dropped on the floor. Only the adaptor's
/// instance is guaranteed to be this object.
///
/// ⛔ THE REFERENCE IS WEAK. The registrar is owned by `DistrictApp` for the
/// lifetime of the process; a strong reference here would be a second owner with a
/// different lifetime, and the delegate outlives the SwiftUI graph on the way down.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// ⚠️ `lazy` ON BOTH, AND NOT FOR COST. UIKit instantiates this class through
    /// the ObjC runtime, so the only initialiser it has is the one inherited from
    /// `NSObject`; declaring `override init()` on a `@MainActor` class to build a
    /// main-actor-isolated property is a change of isolation on an override, which
    /// is a Swift 6 diagnostic. A `lazy` initial value is evaluated at first
    /// ACCESS, and every access below is from a main-actor delegate callback.
    private lazy var relay = PushTapRelay()
    private lazy var presenter = NotificationPresenter(relay: relay)

    /// ⛔ NOT `weak`, UNLIKE ``registrar``, BECAUSE NOTHING ELSE OWNS IT. The
    /// registrar and the incoming model belong to `DistrictApp`; this adapter is
    /// created here and its only reference is the registry's `delegate`, which is
    /// itself `weak`. A weak reference would deallocate it immediately and every
    /// VoIP push would reach nothing — which terminates the app.
    private lazy var voip = VoIPPushHandler()

    /// ⚠️ RETAINED DELIBERATELY. `PKPushRegistry` stops delivering the moment it is
    /// deallocated, and the delivery is what keeps the app alive.
    private var voipRegistry: PKPushRegistry?

    private weak var registrar: PushRegistrar?

    /// Whether ``adopt(registrar:)`` has run and the reference is still alive.
    ///
    /// ⚠️ EXISTS FOR `AppDelegateAdoptionTests`, AND IT EARNS ITS KEEP: the bug it
    /// pins produced no error, no log and no crash — a device token simply arrived
    /// at a nil reference and was discarded. Nothing else in the app can observe
    /// the difference between adopted and not.
    var hasAdoptedRegistrar: Bool {
        registrar != nil
    }

    /// ⚠️ THE DELEGATE IS SET AT LAUNCH, NOT WHEN PUSH IS ENABLED, AND THE
    /// DIFFERENCE IS A LOST NOTIFICATION. `UNUserNotificationCenter` delivers the
    /// response for the notification that LAUNCHED the app only if a delegate is
    /// already installed when launching finishes. Setting it later — say, alongside
    /// the authorization request — means every cold launch from a tap arrives with
    /// nowhere to go.
    ///
    /// ⛔ `launchOptions[.remoteNotification]` IS DELIBERATELY NOT READ, AND A CHANGE
    /// TO "FIX" THAT WOULD INTRODUCE A BUG RATHER THAN CLOSE A GAP. The line
    /// above is what makes a cold launch from a tap route: the response arrives at
    /// ``NotificationPresenter``, `PushTapRelay` buffers it until a
    /// ``PushRegistrar`` exists, and `ShellView` navigates on it: the SAME path a
    /// warm tap takes, which is the property that matters. The launch dictionary is
    /// a second source for that one case and a WRONG source for another: it is
    /// populated for a `content-available` push that woke the app in the background
    /// with nobody touching anything, which this app is entitled to receive
    /// (`UIBackgroundModes: remote-notification`). Routing on it would navigate
    /// somebody who never tapped a notification. If a launch-time read is ever
    /// genuinely needed, it has to be gated on the payload carrying an `aps.alert`,
    /// not adopted wholesale.
    /// ⛔ THE CATEGORIES ARE REGISTERED HERE TOO, AND FOR THE SAME REASON THE DELEGATE
    /// IS. `setNotificationCategories` is what makes `aps.category: "district.message"`
    /// mean Reply and Mark read; it is a local registration that needs no authorization,
    /// so deferring it to the permission prompt would leave a notification arriving on
    /// this launch matched against an empty set and drawn with no buttons — silently,
    /// with nothing reporting a fault. See ``NotificationCategories/register(on:)``.
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = presenter
        NotificationCategories.register()
        registerForVoIPPushes()
        return true
    }

    /// ⛔ AT LAUNCH, NOT AFTER A SIGN-IN, BECAUSE A VoIP PUSH CAN LAUNCH THE APP
    /// COLD. `PKPushRegistry` delivers nothing until `desiredPushTypes` is set, and
    /// the push that started the process is held until it is; setting it alongside
    /// the authorization prompt would mean the ring arrives only when the app
    /// happens to be running, which is never the case it exists for.
    ///
    /// ⛔ `.main` IS WHAT MAKES `MainActor.assumeIsolated` SOUND IN EVERY CALLBACK
    /// OF ``VoIPPushHandler``. The two move together.
    ///
    /// ⚠️ IT COSTS NOTHING ON A BUILD THAT CANNOT RECEIVE PUSHES. A simulator or a
    /// provisioning profile without `aps-environment` simply never issues a
    /// credential, which the handler treats as an ordinary state.
    private func registerForVoIPPushes() {
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = voip
        registry.desiredPushTypes = [.voIP]
        voipRegistry = registry
    }

    /// APNs issued a device token for this installation.
    ///
    /// ⛔ HEX, LOWERCASE, ZERO-PADDED PER BYTE. The server stores the string it is
    /// given and hands it to FCM verbatim; a formatting that dropped a leading zero
    /// would produce a token that is accepted here, written to the row, and
    /// rejected by APNs forever after, with nothing anywhere reporting a fault.
    ///
    /// ⚠️ IT FIRES ON EVERY ROTATION AS WELL AS THE FIRST GRANT, which is the whole
    /// reason the register runs from here rather than once after sign-in.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        registrar?.deviceTokenReceived(hex)
    }

    /// ⛔ NEVER A USER-FACING ERROR. This fires on a simulator with no push service,
    /// on a device with no network at launch, and on a build whose provisioning
    /// profile carries no `aps-environment` — all ordinary, none actionable by the
    /// person holding the phone. Push is a courtesy channel layered on paths that
    /// work without it.
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        registrar?.remoteRegistrationFailed(error)
    }

    /// A remote notification arrived and iOS gave this app background time for it.
    ///
    /// ⛔ THE COMPLETION HANDLER IS CALLED EXACTLY ONCE ON EVERY PATH, INCLUDING THE
    /// ONE WHERE THERE IS NOTHING TO DO. iOS measures an app that does not, and the
    /// penalty is quiet: it is woken for fewer of the pushes it is sent afterwards,
    /// so the symptom is a background refresh that gradually stops working rather
    /// than an error anybody can see. There are exactly two exits below and each
    /// calls it once.
    ///
    /// ⛔ THE WORK IS ONE UNREAD-COUNT READ AND MUST STAY THAT SIZE. The budget is
    /// around thirty seconds and the app is suspended at the end of it; the ⛔ on
    /// ``PushRegistrar/handleSilentPush()`` lists what may not be added.
    ///
    /// ⛔ `userInfo` IS DELIBERATELY NOT READ. The payload carries ids only, by the
    /// server's own decision, and there is nothing in
    /// it this handler needs: the answer is the same for every silent push. Leaving
    /// it alone also keeps a non-`Sendable` `[AnyHashable: Any]` out of the closure
    /// below, which is the shape ``NotificationPresenter`` has to flatten before it
    /// can hop. A TAP is a different path and already lands there.
    ///
    /// ⚠️ ISOLATION, WHICH IS THE LINE MOST LIKELY TO BE WRONG HERE.
    /// `UIApplicationDelegate` is `@MainActor` in the SDK, which is why every method
    /// in this file satisfies its requirements without a `nonisolated` (contrast
    /// ``VoIPPushHandler``, whose `PKPushRegistryDelegate` is not annotated and whose
    /// callbacks therefore are). So this body, and the `Task { @MainActor in }`
    /// below, both run on the main actor and the handler is never called from
    /// anywhere else. The one thing Swift 6 still objects to is CAPTURING it: the
    /// escaping closure parameter is not `Sendable`, so it is rebound
    /// `nonisolated(unsafe)` first, exactly as ``VoIPPushHandler/deliver(_:to:)``
    /// rebinds PushKit's. ``PushRegistrar`` needs no such rebinding: it is a
    /// `@MainActor` class and never leaves the actor.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // ⚠️ NO REGISTRAR MEANS NO SIGNED-IN SESSION IN THIS PROCESS. It attaches at
        // the sign-in (``PushRegistrar/enableAfterSignIn()``), so its absence is the
        // cold-launch and signed-out case: there is nothing to read and nothing to
        // report, and saying so costs no request.
        guard let registrar else {
            completionHandler(.noData)
            return
        }
        nonisolated(unsafe) let finish = completionHandler
        Task { @MainActor in
            let outcome = await registrar.handleSilentPush()
            // ⚠️ AFTER THE READ, NEVER BEFORE. Calling it first tells iOS this app is
            // done with a push it has not acted on yet.
            finish(outcome)
        }
    }

    /// Learn about the one ``PushRegistrar``, and hand it anything already tapped.
    ///
    /// ⚠️ CALLED BY THE REGISTRAR, NOT BY `DistrictApp`. Reaching for the adaptor's
    /// value inside `App.init()` is outside what SwiftUI promises about a
    /// `DynamicProperty`; the registrar attaching itself immediately before it asks
    /// for a device token gives the same result with an ordering that cannot race.
    func adopt(registrar: PushRegistrar) {
        self.registrar = registrar
        relay.adopt(registrar: registrar)
        // ⚠️ THE VoIP TOKEN USUALLY ARRIVES FIRST. The registry is created at
        // launch and the registrar attaches itself at a sign-in, so the handler
        // has almost always been holding a credential by the time this runs.
        voip.adopt(registrar: registrar)
    }

    /// Learn about the one ``IncomingCallModel``, and hand it anything already
    /// ringing.
    ///
    /// ⚠️ CALLED FROM THE ROOT VIEW'S FIRST APPEARANCE RATHER THAN FROM A SIGN-IN,
    /// unlike ``adopt(registrar:)``. A VoIP push has to be answerable on a handset
    /// whose session is still being checked — see ``IncomingCallSession`` — so the
    /// model attaches as early as there is a view, not as late as there is a
    /// session.
    func adopt(incoming: IncomingCallModel) {
        voip.adopt(incoming: incoming)
    }
}
