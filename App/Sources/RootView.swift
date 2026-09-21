import SwiftUI

/// The session gate: the one place that decides between the app and the sign-in
/// screen.
///
/// ⛔ SIGN-IN IS NOT A NAVIGATION DESTINATION, AND THIS FILE IS WHY IT DOES NOT NEED
/// TO BE. Whether a session exists is derived state, not a place; putting sign-in in
/// a back stack means owning the invariant "you may never navigate back into the app
/// after signing out", which a back stack quietly violates. Choosing between two
/// subtrees here makes that invariant structural.
///
/// ⛔ THE FOUR PHASES ARE NOT THREE. ``AuthPhase/unavailable(_:)`` means the session
/// is INTACT and we could not check it (a locked Keychain, a throttled refresh, a
/// request that never left the device); its offer is "try again", not "sign in".
/// Collapsing it into the signed-out branch tells a paying customer their account is
/// gone because their phone was locked.
struct RootView: View {
    private let container: AppContainer

    /// ⚠️ THREADED THROUGH RATHER THAN BUILT HERE. `DistrictApp` owns the one
    /// registrar for the process; see the ⛔ on ``PushRegistrar``.
    private let push: PushRegistrar

    /// ⚠️ THREADED THROUGH LIKE ``push``, AND FOR A STRONGER REASON. A ring can
    /// arrive before this gate resolves, so the model is told about every phase
    /// rather than being built inside the signed-in branch. See the ⛔ on
    /// ``IncomingCallSession``.
    private let incoming: IncomingCallModel

    @State private var session: SessionModel

    init(container: AppContainer, push: PushRegistrar, incoming: IncomingCallModel) {
        self.container = container
        self.push = push
        self.incoming = incoming
        // ⚠️ `State(initialValue:)` in `init` is the `@Observable` equivalent of the
        // old `StateObject(wrappedValue:)` autoclosure: SwiftUI keeps the value for
        // the lifetime of this view's identity, so the model is not rebuilt on every
        // re-render. Constructing it in the body would be a new model per frame.
        _session = State(initialValue: SessionModel(container: container, push: push))
    }

    var body: some View {
        SessionGate(container: container, session: session, push: push, incoming: incoming)
            // ⚠️ THE BRAND TINT, PUBLISHED ONCE, ABOVE EVERYTHING. It is the only part
            // of the theme that travels through the environment: the palette itself
            // is derived per view from `colorScheme`, so a subtree that forgets this
            // modifier is still correctly coloured and merely loses the tint on
            // SwiftUI's own controls. See `DistrictColors.resolve(_:)`.
            .districtTheme()
            .task {
                // ⚠️ Runs once per appearance of this view identity, not on every
                // redraw. A refresh here can spend a rotation; see `refreshPhase`.
                await session.refreshPhase()
            }
    }
}

/// ⚠️ A SEPARATE VIEW BECAUSE IT PAINTS THE PAGE. The window is otherwise the
/// platform's own background, which is white in light mode and a system grey in
/// dark, and every screen below would then sit on a colour that appears nowhere in
/// the palette. One `ZStack` here is cheaper than a background modifier on every
/// branch, and it cannot be forgotten on the branch nobody looks at.
private struct SessionGate: View {
    let container: AppContainer
    let session: SessionModel
    let push: PushRegistrar
    let incoming: IncomingCallModel

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        ZStack {
            colors.background.ignoresSafeArea()
            content
        }
        // ⛔ EVERY PHASE, INCLUDING `checking`, AND `initial: true` BECAUSE THE
        // GATE MAY HAVE RESOLVED BEFORE THIS VIEW FIRST DREW. A ring that arrived
        // during `checking` is held rather than refused, and this is the only thing
        // that ever resolves it — in either direction. See the ⛔ on
        // ``IncomingCallSession``.
        .onChange(of: session.phase, initial: true) { sessionChanged() }
    }

    /// ⛔ THE ROOM IS ENDED WHENEVER THIS GATE LEAVES `signedIn`, AND THAT IS THE ONLY
    /// PLACE THAT CAN DO IT. Every other branch below renders INSTEAD of ``ShellView``,
    /// which destroys the whole tab subtree and with it the room screen; the meeting
    /// itself would carry on, publishing a microphone and a camera with no controls
    /// anywhere on screen, because ``CallStack`` holds the live room for exactly the
    /// reason it holds a live call. Signing out of a meeting is reachable in two taps
    /// from the Account tab.
    ///
    /// ⚠️ `checking` CANNOT RECUR MID-SESSION, so this does not tear a meeting down for
    /// a transient re-check: ``SessionModel/phase`` starts there and
    /// ``SessionModel/refreshPhase()`` only ever writes the other three. The
    /// `initial: true` firing above therefore reaches an empty ``CallStack``.
    ///
    /// ⚠️ `unavailable` ENDS IT TOO, EVEN THOUGH THE SESSION IS INTACT. The room's own
    /// LiveKit token is unaffected, but the screen that drives it is gone either way,
    /// and a live microphone nobody can reach is the worse half of that trade.
    private func sessionChanged() {
        incoming.sessionChanged(session.phase)
        if case .signedIn = session.phase {
            return
        }
        Task { await container.callStack.endRoom(.sessionEnded) }
    }

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .checking:
            LoadingView(message: "Checking your session…")

        case .signedIn:
            // ⛔ THE REGISTRAR GOES DOWN AS WELL AS BEING ENABLED HERE, AND THIS
            // BRANCH IS WHY A SIGNED-OUT DEVICE ROUTES NOTHING. `ShellView` reads
            // the tapped payload and navigates on it; reachable only from here, so
            // the session gate is the gate on notification routing too. See the ⛔
            // on ``ShellView``.
            ShellView(container: container, session: session, push: push, incoming: incoming)
                // ⛔ THE ONE PLACE PUSH IS TURNED ON, AND IT IS HERE RATHER THAN AT
                // LAUNCH BECAUSE THE REGISTER NEEDS A BEARER. Before a sign-in
                // there is none, so a register would spend a 401 against a 20/min
                // per-account ceiling and record nothing — and the server's upsert
                // is keyed on the INSTALLATION, so until this account claims the
                // row a handset previously signed in as somebody else keeps
                // delivering THEIR notifications.
                //
                // ⚠️ `onAppear` RATHER THAN `task`, AND SAFE TO REPEAT. The gate
                // rebuilds this branch on every transition back into signed-in, and
                // a returning appearance may fire it again; the authorization
                // prompt is guarded to once per launch and the register is skipped
                // locally when the token is unchanged. See
                // ``PushRegistrar/enableAfterSignIn()``.
                .onAppear { push.enableAfterSignIn() }
                // ⛔ THE MICROPHONE IS ASKED HERE TOO, AND A TELEPHONE APP ASKING AT LANDING IS
                // DELIBERATE. A call answered from the lock screen, a car or a headset cannot put a
                // permission alert in front of anybody, so without this its first answer fails at the
                // media join. ⚠️ Asks only a question nobody has answered; see
                // ``MicrophoneAccess/askAtLanding()``.
                .task { await container.callStack.microphone.askAtLanding() }

        case let .signedOut(reason):
            SignInView(
                reason: reason,
                actionTitle: "Sign in",
                isBusy: session.isBusy,
                action: { Task { await session.signIn() } },
                // ⛔ THE APPLE DOOR IS OFFERED ON THIS BRANCH AND ONLY THIS ONE.
                // App Store Review Guideline 4.8 asks for it wherever a
                // third-party sign-in is offered; the `unavailable` branch below
                // offers a session RE-CHECK, not a sign-in. See the ⛔ on
                // ``AppleSignInHandlers``.
                apple: AppleSignInHandlers(
                    prepare: { container.appleLogin.prepare($0) },
                    finish: { result in Task { await session.signInWithApple(result) } }
                )
            )

        case let .unavailable(reason):
            // ⛔ A DISTINCT BRANCH FROM `signedOut`, DELIBERATELY. The session is
            // intact here and the offer is "try again", not "sign in".
            SignInView(
                reason: reason,
                actionTitle: "Try again",
                isBusy: session.isBusy,
                action: { Task { await session.refreshPhase() } }
            )
        }
    }
}
