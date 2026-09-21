import AuthenticationServices
import SwiftUI
import UIKit

/// Apple's Sign in with Apple control, hosted by hand so the UIKit view itself
/// carries the accessibility identifier.
///
/// ⛔ NOT `SignInWithAppleButton`, AND THE REASON WAS MEASURED, NOT ASSUMED. The
/// SwiftUI wrapper takes `.accessibilityIdentifier` without complaint and then
/// exposes NOTHING under it: `test_IOS_AUTH_04_signInWithAppleIsOffered` waits its full
/// 30 seconds for `district-sign-in-apple` and finds no element, while the sibling
/// `.districtPrimary` button two lines above it is found by the same query every
/// run. The representable's UIKit control is what XCUITest walks, and SwiftUI
/// modifiers applied outside a representable do not reach it. Setting
/// `accessibilityIdentifier` on the `ASAuthorizationAppleIDButton` is the only
/// placement that shows up, and that is the whole reason this file exists.
///
/// ⚠️ WHAT IS REIMPLEMENTED IS SMALL AND BOUNDED: one target-action, one
/// `ASAuthorizationController`, its delegate, and a presentation anchor lifted
/// from ``WebAuthLoginController``. The nonce, the request scopes and the
/// exchange are NOT here; they stay in ``AppleSignInController`` behind the same
/// two closures `SignInWithAppleButton` used, so ``AppleSignInHandlers`` is
/// unchanged and so are its tests.
///
/// ⚠️ THE STYLE IS FIXED AT INIT BY UIKit, so a colour-scheme change has to
/// rebuild the control; ``SignInView`` does that with `.id(colorScheme)`.
struct AppleIDButton: UIViewRepresentable {
    let style: ASAuthorizationAppleIDButton.Style
    let cornerRadius: CGFloat
    let identifier: String
    let onRequest: (ASAuthorizationAppleIDRequest) -> Void
    let onCompletion: (Result<ASAuthorization, any Error>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onRequest: onRequest, onCompletion: onCompletion)
    }

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .signIn, style: style)
        button.cornerRadius = cornerRadius
        button.accessibilityIdentifier = identifier
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        return button
    }

    func updateUIView(_ uiView: ASAuthorizationAppleIDButton, context: Context) {
        uiView.accessibilityIdentifier = identifier
        context.coordinator.onRequest = onRequest
        context.coordinator.onCompletion = onCompletion
    }

    /// The delegate for one tap's `ASAuthorizationController`.
    ///
    /// ⚠️ THE CONTROLLER IS HELD FOR THE LENGTH OF THE SHEET. `performRequests()`
    /// does not retain its controller; dropping it on the floor after the call
    /// ends the authorisation with no callback, which presents exactly like a
    /// user cancelling.
    final class Coordinator: NSObject {
        var onRequest: (ASAuthorizationAppleIDRequest) -> Void
        var onCompletion: (Result<ASAuthorization, any Error>) -> Void
        private var controller: ASAuthorizationController?

        init(
            onRequest: @escaping (ASAuthorizationAppleIDRequest) -> Void,
            onCompletion: @escaping (Result<ASAuthorization, any Error>) -> Void
        ) {
            self.onRequest = onRequest
            self.onCompletion = onCompletion
        }

        @objc func tapped() {
            let request = ASAuthorizationAppleIDProvider().createRequest()
            onRequest(request)
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }
    }
}

extension AppleIDButton.Coordinator: ASAuthorizationControllerDelegate {
    func authorizationController(
        controller _: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        controller = nil
        onCompletion(.success(authorization))
    }

    func authorizationController(controller _: ASAuthorizationController, didCompleteWithError error: any Error) {
        controller = nil
        onCompletion(.failure(error))
    }
}

extension AppleIDButton.Coordinator: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for _: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.first { $0.activationState == .foregroundActive }?.keyWindow
            ?? scenes.first?.keyWindow
        // ⚠️ Same fallback as `WebAuthLoginController`: an empty anchor fails
        // the sheet and reports through `didCompleteWithError`, rather than
        // crashing on a launch-time race.
        return window ?? ASPresentationAnchor()
    }
}
