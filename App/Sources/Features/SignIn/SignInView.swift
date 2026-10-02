import AuthenticationServices
import SwiftUI

/// The sign-in surface: two doors, and a sentence saying why either is being
/// asked for. Ports Android's `SignInScreen.kt`, which has one.
///
/// ⛔ SIGN-IN IS NOT A NAVIGATION DESTINATION. ``RootView``'s gate chooses between
/// this and the shell, because whether a session exists is derived state rather
/// than a place. See the ⛔ at the top of `RootView.swift`.
///
/// ⛔ TWO BUTTONS, AND THE SECOND ONE IS THERE BECAUSE OF APP STORE REVIEW
/// GUIDELINE 4.8. The first door opens the server's own login surface, which offers
/// Google and Microsoft SSO; 4.8 requires an app that offers a third-party sign-in service
/// to ALSO offer an equivalent privacy-preserving option, so Sign in with Apple
/// is not an extra convenience here, it is what keeps the binary reviewable. The
/// rule is about what is OFFERED, so deleting the Apple button while the web
/// surface keeps its two puts the app in violation.
///
/// ⛔ AND NOTHING ELSE LEAVES THIS SCREEN: no offer to create an
/// account, subscribe or "learn more" — every path out of this screen that is not
/// one of the two sign-in handshakes is a purchase path under Guideline 3.1.3(b)
/// — and this screen still collects NO credentials. The password and both SSO
/// providers live on the server's own login surface and a native form could not
/// reach them; Apple's sheet is the system's, and nothing typed into it is
/// visible to this process.
///
/// ⚠️ THE INPUTS ARE THE GATE'S, NOT A MODEL'S. ``actionTitle`` is what carries the
/// difference between the two branches that render this screen: `signedOut` offers
/// "Sign in", `unavailable` offers "Try again" because the session is INTACT and
/// the offer is to re-check it. A screen that owned its own model could not tell
/// those apart.
struct SignInView: View {
    /// The sentence ``SessionModel`` wrote for the phase that produced this screen.
    ///
    /// ⛔ IT IS ALWAYS SHOWN. "Sign in" with no explanation is what turns a locked
    /// Keychain into a support ticket.
    let reason: String
    let actionTitle: String
    let isBusy: Bool
    let action: () -> Void

    /// The Apple door, or nil where there is no sign-in to offer.
    ///
    /// ⛔ NIL ON THE `unavailable` BRANCH, DELIBERATELY. That branch renders this
    /// same screen to say "we could not CHECK your session" and offers "Try
    /// again", which re-reads the coordinator; the session is intact. An Apple
    /// button there would offer a fresh sign-in to a signed-in user and mint a
    /// second device session for the same handset. Guideline 4.8 asks for the
    /// option wherever sign-in is offered, and that branch does not offer one.
    var apple: AppleSignInHandlers?

    @Environment(\.colorScheme) private var colorScheme

    /// ⚠️ THE SAME SEAM `AccountView` OPENS ITS DELETION PAGE THROUGH, and it opens
    /// in the user's own browser session — which this app neither holds nor may
    /// supply. See ``SignInTermsCopy``.
    @Environment(\.openURL) private var openURL

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(spacing: DistrictSpacing.row) {
            DistrictEyebrow(text: "District AI")
            Text("District AI")
                .font(DistrictType.headlineLarge)
                .foregroundStyle(colors.foreground)
            Text("Sign in to your workspace.")
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
                .multilineTextAlignment(.center)
            Button(actionTitle, action: action)
                .buttonStyle(.districtPrimary)
                .disabled(isBusy)
                .padding(.top, DistrictSpacing.tight)
                // ⚠️ IDENTITY, NOT THE LABEL. ``actionTitle`` is supplied by the gate
                // and differs between "Sign in" and a retry, so a test matching the
                // WORDS would pass on one path and fail on the other for no reason.
                .accessibilityIdentifier(A11yID.SignIn.button)
            // ⚠️ THE BROWSER HAND-OFF IS STATED UP FRONT. Sign-in leaves the app,
            // and a user who is not expecting that reads the browser opening as a
            // crash or a redirect they did not ask for.
            Text("Opens your browser to sign in securely.")
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .multilineTextAlignment(.center)
            appleButton
            if isBusy {
                ProgressView()
            }
            statusPanel
            // ⛔ UNDER THE CONTROLS AND ON THIS SCREEN, WHICH IS THE GUIDELINE 1.2
            // REQUIREMENT ITSELF. The terms have to be presented BEFORE sign-in, not
            // behind the gate on an Account screen. See ``SignInTermsCopy``.
            // ⚠️ BELOW `statusPanel`, so a sign-in reason never pushes it off a small
            // screen: the reason is the thing the user has to act on, and the terms
            // line is the thing that must still be visible when they do.
            termsLine
        }
        // ⚠️ Narrower than the screen. A login card stretched to a list's reading
        // width looks like a form that lost its fields; the web's own login card is
        // `max-w-md`, and Android caps this at 480dp for the same reason.
        .frame(maxWidth: Self.cardMaxWidth)
        .padding(DistrictSpacing.header)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // ⛔ `.contain` FIRST, AND WITHOUT IT THE ROOT'S IDENTIFIER SWALLOWS THE
        // SCREEN. `.accessibilityIdentifier` on a container is an INHERITED property
        // in SwiftUI: applied alone here it propagates to every descendant, so the
        // sign-in button, the status line and three labels all report
        // `district-sign-in-root` and the button's own identifier is overwritten.
        // Measured from `app.debugDescription`, not reasoned about. `.contain` makes
        // this an accessibility CONTAINER, so the identifier lands on it alone and
        // the children keep their own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.SignIn.root)
    }

    /// The Guideline 4.8 door.
    ///
    /// ⛔ APPLE'S OWN BUTTON, AND ITS COLOURS ARE NOT OURS TO CHOOSE. The Human
    /// Interface Guidelines allow exactly three appearances — black, white, and
    /// white with an outline — and a recoloured or relabelled Sign in with Apple
    /// button is a review rejection in its own right. "Styled to the palette"
    /// therefore means picking the appearance that reads correctly against
    /// ``DistrictColors/background`` (white on our dark page, black on our light
    /// one) and matching the SHAPE and HEIGHT of ``DistrictButtonStyle`` so the
    /// two doors look like siblings. The corner radius and the 44pt floor are
    /// the same tokens `.districtPrimary` uses.
    ///
    /// ⛔ ``AppleIDButton`` RATHER THAN `SignInWithAppleButton`. The SwiftUI
    /// wrapper accepts `.accessibilityIdentifier` and exposes nothing under it to
    /// XCUITest; `test_IOS_AUTH_04` finds no element in 30 seconds while the sibling
    /// button above it is found every run. The hosted control sets the
    /// identifier on the UIKit view, which is the one placement that shows up.
    /// The nonce and the exchange stay in ``AppleSignInController`` behind the
    /// same two closures.
    ///
    @ViewBuilder
    private var appleButton: some View {
        if let apple {
            AppleIDButton(
                style: colorScheme == .dark ? .white : .black,
                cornerRadius: DistrictRadius.control,
                identifier: A11yID.SignIn.apple,
                onRequest: { apple.prepare($0) },
                onCompletion: { apple.finish($0) }
            )
            // ⚠️ THE STYLE IS FIXED AT INIT BY UIKit; a scheme change rebuilds
            // the control rather than restyling it.
            .id(colorScheme)
            // ⛔ A FIXED HEIGHT AND AN INTRINSIC WIDTH, NOT `maxWidth: .infinity`
            // WITH A `minHeight`. A hosted UIKit view reports no maximum, so it
            // would grow to fill every point the card had left below the caption: a
            // black slab two thirds of the screen tall. `fixedSize` keeps Apple's own
            // content width, which is what makes it read as a sibling of the
            // compact `.districtPrimary` button above it.
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: DistrictButtonSize.medium.minHeight)
            .disabled(isBusy)
            // ⚠️ THE LABEL IS APPLE'S OWN, localised by the control; the
            // identifier is set INSIDE the representable, see ``AppleIDButton``.
            .accessibilityLabel("Sign in with Apple")
        }
    }

    /// The Guideline 1.2 disclosure.
    ///
    /// ⛔ THREE VIEWS RATHER THAN ONE MARKDOWN `Text`, AND THE REASON IS THE
    /// RECORDING. `Text("… [Terms](url) …")` renders tappable links and opens them
    /// correctly, and XCUITest cannot address either one — a markdown link inside a
    /// `Text` is not an element, so a walk asked to show a reviewer the terms being
    /// opened could only tap the whole sentence and hope. Two `Button`s carry
    /// ``A11yID/SignIn/termsLink`` and ``A11yID/SignIn/privacyLink``, which is what
    /// makes the shot list repeatable.
    ///
    /// ⛔ AND THE IDENTIFIER GOES ON THE CONTAINER WITH `.contain` FIRST. Applied
    /// alone it is INHERITED by every descendant in SwiftUI, which would overwrite
    /// both links' own names — the same trap this file's root already documents,
    /// measured there from `app.debugDescription` rather than reasoned about.
    ///
    /// ⚠️ TWO LINES BY LAYOUT, ONE SENTENCE BY READING. The prefix wraps above the
    /// pair so the links stay on one row at every Dynamic Type size; the string a
    /// reader assembles is ``SignInTermsCopy/sentence``, which is what the copy test
    /// pins.
    private var termsLine: some View {
        VStack(spacing: DistrictSpacing.hairline) {
            Text(SignInTermsCopy.prefix)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            // ⚠️ `spacing: 0` BECAUSE THE FRAGMENTS CARRY THEIR OWN SPACES. A
            // container gap is not in the string, so the sentence a test compares
            // and the sentence on screen would differ by exactly the padding.
            HStack(spacing: 0) {
                legalLink(SignInTermsCopy.termsName, SignInTermsCopy.termsURL, A11yID.SignIn.termsLink)
                Text(SignInTermsCopy.conjunction)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
                legalLink(SignInTermsCopy.privacyName, SignInTermsCopy.privacyURL, A11yID.SignIn.privacyLink)
                Text(SignInTermsCopy.terminator)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.top, DistrictSpacing.tight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.SignIn.terms)
    }

    /// One legal page, as a control rather than a link.
    ///
    /// ⚠️ `.districtGhost` IS NOT USED HERE AND THAT IS DELIBERATE. Every button
    /// style in the design system carries a 44pt minimum height, which on a
    /// caption-sized inline link would break the sentence into two tall slabs. The
    /// underline is what says "tappable"; the tap target is the text's own frame,
    /// which is why the two names are the only words on their line.
    ///
    /// ⚠️ SILENT ON A NIL URL rather than force-unwrapping. See ``SignInTermsCopy``.
    private func legalLink(_ title: String, _ url: URL, _ identifier: String) -> some View {
        Button(title) {
            openURL(url)
        }
        .buttonStyle(.plain)
        .font(DistrictType.caption)
        .foregroundStyle(colors.district)
        .underline()
        .accessibilityIdentifier(identifier)
    }

    /// ⛔ A TONED STATUS, NOT UNDIFFERENTIATED GREY TEXT. "You appear to be offline"
    /// and "that sign-in could not be verified" are not the same kind of message,
    /// and the second is the authorization-code-injection case: a callback whose
    /// `state` did not match the one this app generated, meaning something tried to
    /// bind this app's session to an account the user did not choose. It must not
    /// read as a progress note. Ports Android's `StatusPanel`.
    ///
    /// ⚠️ ABSENT ON A COLD START. `SessionModel` hands an EMPTY reason for
    /// `.noSession`, because the screen's own subtitle already tells a new user
    /// what to do and a second instruction here reads as a duplicate. The slot is for
    /// reasons, not for restating the task.
    @ViewBuilder
    private var statusPanel: some View {
        if !reason.isEmpty {
            Text(reason)
                .font(DistrictType.bodySmall)
                .foregroundStyle(SignInStatusTone.forReason(reason).ink(colors))
                .multilineTextAlignment(.center)
                .padding(.top, DistrictSpacing.tight)
                .accessibilityIdentifier(A11yID.SignIn.status)
        }
    }

    private static let cardMaxWidth: CGFloat = 480
}

/// Which ``Tone`` a sign-in reason wears. Ports Android's `LoginStatusTone.kt`.
///
/// ⚠️ IN THE FEATURE, NOT IN THE DESIGN SYSTEM, which is the same call Android
/// made and for the same reason: a primitive that knows about login reasons has
/// stopped being a primitive. `DistrictColors`, `Tone` and the button styles
/// depend on nothing above them and must stay that way.
///
/// ⛔ IT MATCHES THE WHOLE SENTENCE, AND THE SETS HOLD ``SessionCopy``'s CONSTANTS,
/// the same ones ``SessionModel`` writes into the phase. Android could switch over a
/// `LoginStatus` enum; this client is handed the rendered string, because the gate
/// passes ``AuthPhase``'s associated value. Naming each sentence once is what keeps a
/// rewording from silently demoting a message to neutral.
///
/// ⚠️ NEUTRAL IS THE FALLBACK because it is the QUIET one: an unrecognised sentence
/// rendered calmly is a cosmetic miss, whereas defaulting to danger would paint a
/// routine 60-day sign-out red.
enum SignInStatusTone {
    static func forReason(_ reason: String) -> Tone {
        if danger.contains(reason) {
            return .danger
        }
        if warning.contains(reason) {
            return .warning
        }
        if info.contains(reason) {
            return .info
        }
        // Everything else is a plain statement of fact: "Sign in to continue.",
        // "You are signed out.", "You have been signed out after 60 days." and the
        // server-authored "Sign-in was not completed (…)." — which stays neutral
        // because its reason could be anything from a cancelled consent screen to
        // a policy refusal, a severity this client cannot judge.
        return .neutral
    }

    /// ⛔ HOSTILE, NOT MERELY FAILED. A state mismatch is a REFUSED callback and a
    /// rejected refresh is how a replayed token presents, which the server treats
    /// as theft and answers by revoking the whole token family.
    private static let danger: Set<String> = [
        SessionCopy.signInNotVerified,
        SessionCopy.refreshRejected,
    ]

    /// Recoverable by trying again: worth flagging, not worth alarming.
    ///
    /// ⚠️ "Your session ended unexpectedly" IS HERE RATHER THAN IN `danger`. It
    /// means the app was killed mid-refresh, so the stored token is presumed
    /// spent — not a security event, and `SessionModel` carries a ⛔ saying it must
    /// never be worded as one. Colouring it red would say what the wording refuses
    /// to.
    private static let warning: Set<String> = [
        SessionCopy.signInExpired,
        SessionCopy.tooManyAttempts,
        SessionCopy.unreachable,
        SessionCopy.refreshThrottled,
        SessionCopy.refreshNotSent,
        SessionCopy.storeUnavailable,
        SessionCopy.markerNotDurable,
        SessionCopy.interruptedRefresh,
        SessionCopy.refreshUnreachable,
    ]

    /// Nothing failed and nothing is worth retrying: the user needs something
    /// only another person can give them.
    ///
    /// ⛔ ``SignInCopy/noAccount`` IS HERE, NOT IN `warning` OR `danger`. An Apple
    /// ID with no account is an invitation problem, and colouring it as a failure
    /// invites the retry loop that cannot succeed; a "check your connection" answer
    /// reads to a reviewer as broken sign-in.
    private static let info: Set<String> = [
        SignInCopy.noAccount,
    ]
}
