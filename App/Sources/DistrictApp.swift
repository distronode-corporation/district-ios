import SwiftUI

/// The entry point.
///
/// ⛔ THE CONTAINER IS BUILT HERE AND ONLY HERE, AND IT IS A `let`. Everything in
/// ``AppContainer``'s ⛔ note depends on there being exactly one of it: one
/// ``TokenRefreshCoordinator`` (two would each hold a single-flight gate the
/// other cannot see, and presenting the same refresh token twice revokes the
/// user's whole token family). A second
/// `AppContainer()` anywhere — a preview, a helper, a feature that finds it
/// easier than threading the reference — reintroduces exactly that.
///
/// ⚠️ `RootView` IS THE SESSION GATE, NOT A PLACEHOLDER. It chooses between the
/// sign-in surface and `ShellView`, and it is the one place that decision is made:
/// sign-in is deliberately not a navigation destination, so nothing below it can
/// navigate back into the app after a sign-out.
@main
struct DistrictApp: App {
    /// ⛔ THE ADAPTOR IS DECLARED AND NEVER READ HERE, WHICH IS THE POINT OF IT.
    /// Declaring it is what makes SwiftUI drive `UIApplicationMain` with our
    /// ``AppDelegate`` — the only way to receive the APNs device-token callbacks and
    /// to install the `UNUserNotificationCenter` delegate early enough for a cold
    /// launch from a notification tap. ⚠️ It is deliberately not read from `init()`:
    /// a `DynamicProperty` is only promised to be valid inside `body`, and the
    /// registrar hands ITSELF to the delegate instead (see
    /// ``PushRegistrar/enableAfterSignIn()``).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let container: AppContainer

    /// ⛔ ONE PER PROCESS, LIKE THE CONTAINER, AND FOR A NARROWER REASON: it holds
    /// the "have we already raised the system prompt this launch" flag and the
    /// pending notification-tap payload. A second one would let the prompt be
    /// raised twice and would hold the payload nothing was reading.
    private let push: PushRegistrar

    /// ⛔ ONE PER PROCESS AND IT MUST OUTLIVE EVERY VIEW, FOR A REASON THE OTHER
    /// TWO DO NOT SHARE: a VoIP push can arrive with no window on screen, during a
    /// cold launch, or while the user is on a different tab. A model owned by a
    /// view would not exist to receive it, and one rebuilt on a redraw would lose
    /// the call mid-conversation. See the ⛔ on ``IncomingCallModel``.
    private let incoming: IncomingCallModel

    init() {
        // ⛔ FIRST LINE, BEFORE THE CONTAINER. `AppContainer.init` reads the
        // Keychain and builds the entire object graph, and a crash in there is
        // precisely the crash worth a report: it happens on a stranger's phone, on
        // a launch, with nothing on screen to describe it. A handler installed
        // after the graph exists cannot see it.
        //
        // ⚠️ A NO-OP UNLESS A DSN WAS BUILT IN, which is every build except an
        // archive from `scripts/archive-imac.sh`. See ``DistrictSentry``: with a
        // blank `SENTRY_DSN` nothing is started, so this line costs one
        // `Info.plist` read on the simulator and in CI.
        DistrictSentry.startIfConfigured()

        let container = AppContainer()
        self.container = container
        push = PushRegistrar(container: container)
        incoming = IncomingCallModel(container: container)
    }

    var body: some Scene {
        WindowGroup {
            RootView(container: container, push: push, incoming: incoming)
                // ⛔ THE REVOKE OUTBOX IS DRAINED HERE, AND THIS IS THE ONLY HOOK
                // THAT ALWAYS RUNS. A sign-out whose `POST
                // /api/auth/native/revoke` could not reach the server leaves the
                // refresh token in the store's outbox, and something has to come
                // back for it — but every state-dependent trigger is conditional
                // on state the signed-out user no longer has. Hanging it off the
                // login controller fires only if someone signs in again; hanging
                // it off the first token acquisition fires only when there IS a
                // session, which is exactly what a signed-out device lacks. The
                // root view is presented on every cold start either way.
                //
                // ⚠️ COSTS ONE KEYCHAIN READ IN THE NORMAL CASE, and makes no
                // network call unless there is genuinely a token to chase. It
                // does not gate the UI: `.task` runs after the first render.
                .task { await container.drainPendingRevoke() }
                // ⛔ `onAppear` RATHER THAN `.task`, BECAUSE THIS ONE RACES A PUSH.
                // `.task` runs after the first render; `onAppear` runs with it, and
                // a VoIP push that beats even that is buffered by ``VoIPPushHandler``.
                // ⛔ THE ONE PLACE THE DELEGATE LEARNS ABOUT EITHER OBJECT, AND IT
                // GOES THROUGH THE ADAPTOR'S OWN INSTANCE, never through a cast of
                // `UIApplication.shared.delegate as? AppDelegate`. ⛔ THAT CAST FAILS:
                // measured on an iPhone XS Max, iOS 18.7.10, the delegate does not
                // cast to `AppDelegate`, so a fallback that returned silently on it
                // would leave a device token going nowhere and a VoIP push with
                // nothing to ring, in the SHIPPING configuration and not only in a
                // preview or a test host. A fallback that never succeeds is worse
                // than none: it is indistinguishable from a feature that does not
                // exist. `appDelegate` is non-optional — the adaptor guarantees the
                // instance — so there is no failure branch to be quiet about.
                //
                // ⚠️ ABOVE THE SESSION GATE, unlike the notification wiring on
                // `ShellView`, because a ring must be reported to CallKit on a
                // handset whose session has not resolved. Reading the adaptor
                // inside `body` is exactly what SwiftUI promises; `init()` is not.
                .onAppear {
                    appDelegate.adopt(registrar: push)
                    appDelegate.adopt(incoming: incoming)
                }
        }
        // ⚠️ THE HARDWARE KEYBOARD'S MENU. Every command reads what the signed-in shell
        // publishes and is disabled while nothing does; see ``DistrictCommands``.
        .commands { DistrictCommands() }
    }
}
