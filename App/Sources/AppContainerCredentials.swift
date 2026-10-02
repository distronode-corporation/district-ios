import DistrictAuthCore
import DistrictNetwork
import Foundation
import OSLog
import UIKit

/// The pieces of `AppContainer.init` that are neither container STATE nor part of
/// wiring it: the access-token closure both credentialed clients take, what `api` does
/// with a refused one, and the sign-in doors' construction.
///
/// ⛔ ONE DEFINITION, BECAUSE TWO WOULD BE TWO PLACES TO GET THE REFUSAL WRONG.
/// `accessToken()` returns an outcome, not a token, and only `.available` carries one:
/// every other case (a refresh in flight that failed, a credential the server has
/// revoked) must send NO Authorization header rather than an empty or stale one. Both
/// `api` and `schedulingSSO` take this one closure.
///
/// ⚠️ IN ITS OWN FILE AND `internal` RATHER THAN `private`, WHICH IS A LINT CEILING
/// RATHER THAN A WIDENING WITH MEANING. `AppContainer.swift` sits at SwiftLint's 500-line
/// file limit, and this helper is the one thing in that file that is neither container STATE nor part
/// of constructing it — so it is the honest thing to move. An extension cannot be
/// file-private and still be visible to the initialiser, hence `internal`; nothing else
/// in the app has any use for it.
///
/// ⛔ IT STILL MUST NOT BECOME A SECOND WAY TO REACH A TOKEN. Every caller is inside
/// `AppContainer.init`, and the reason both clients take a CLOSURE rather than a token is
/// on ``AppContainer``'s own `api`: acquiring one may mean waiting behind the
/// coordinator's single-flight refresh, which is asynchronous.
extension AppContainer {
    static func bearer(_ coordinator: TokenRefreshCoordinator) -> @Sendable () async -> String? {
        { [coordinator] in
            guard case let .available(token) = await coordinator.accessToken() else { return nil }
            return token
        }
    }

    /// What `api` does with a bearer the server answered 401: drop THAT token from the
    /// coordinator's cache, so the next call refreshes instead of presenting it again.
    ///
    /// ⛔ INVALIDATE, NEVER RESEND. The failed request is returned to its caller as the
    /// 401 it was; replaying it could double-bill a send or repeat an irreversible write
    /// (see the ⛔ on `ApiClient`). The token argument is what keeps two concurrent 401s
    /// from discarding the fresh token the first one's refresh produced.
    static func rejected(_ coordinator: TokenRefreshCoordinator) -> @Sendable (String) async -> Void {
        { [coordinator] token in
            await coordinator.invalidateAccessToken(token)
        }
    }

    /// The sign-in door, constructed here for the same reason the closure above lives here.
    ///
    /// ⚠️ EXTRACTED BECAUSE `AppContainer.init` IS AGAINST `function_body_length`'s 60.
    /// The controller still takes the SAME `auth` and `coordinator` instances the
    /// container built, and the device name is still read once, at construction. The call
    /// site is one line instead of six because a wrapped call costs a line per argument
    /// under `--wraparguments before-first`.
    ///
    /// ⚠️ IN THIS FILE RATHER THAN BESIDE THE INITIALISER THAT CALLS IT because
    /// `AppContainer.swift` is inside 20 lines of SwiftLint's 500-line file ceiling, which
    /// `--strict` reports as an error rather than a warning. Same pressure that moved
    /// ``bearer(_:)`` here.
    ///
    /// ⛔ IT IS NOT A SECOND CONSTRUCTION SITE. `AppContainer.init` is the only caller, and
    /// ``WebAuthLoginController`` must stay one per process for the reason on
    /// ``AppContainer`` itself: it drives the refresh coordinator there is exactly one of.
    static func loginController(
        baseURL: URL,
        auth: AppNativeAuthClient,
        coordinator: TokenRefreshCoordinator,
        deviceId: String
    ) -> WebAuthLoginController {
        WebAuthLoginController(
            baseURL: baseURL,
            auth: auth,
            coordinator: coordinator,
            deviceId: deviceId,
            deviceName: UIDevice.current.name
        )
    }

    /// The Guideline 4.8 door, constructed here for the same line-budget reason
    /// as its sibling above.
    ///
    /// ⛔ THE SAME `auth` AND `coordinator` INSTANCES, WHICH IS THE ONE THING
    /// THAT MATTERS ABOUT THIS FUNCTION. A second coordinator would hold a
    /// second view of the refresh token and the two would race a rotation, which
    /// the server treats as a replay and answers by revoking the whole family.
    ///
    /// ⚠️ NO `baseURL`. The Apple leg has no browser hand-off to build a URL
    /// for — its only network call goes through `auth`, which already carries
    /// the origin this container was built with.
    static func appleController(
        auth: AppNativeAuthClient,
        coordinator: TokenRefreshCoordinator,
        deviceId: String
    ) -> AppleSignInController {
        AppleSignInController(
            auth: auth,
            coordinator: coordinator,
            deviceId: deviceId,
            deviceName: UIDevice.current.name
        )
    }

    /// The bound scheduling hand-off (S33), the third sign-in door: it signs the
    /// browser into the website rather than the app.
    ///
    /// ⛔ THE LOG LINE NAMES THE PATH AND NOTHING ELSE; the flow never hands it a nonce
    /// or a state. `.public` is safe for exactly that reason, and it is what makes
    /// "path=bound" readable in a device's console during the cookie-jar proof. ⚠️
    /// Sentry's automatic breadcrumbs are off (`DistrictSentry`), so this line reaches
    /// the unified log only.
    ///
    /// ⚠️ `PKCE.newState` IS REUSED FOR THE STATE: 32 random bytes, base64url, which the
    /// hand-off route accepts (`PKCETests` pins that it does).
    static func handoffFlow(_ client: SchedulingHandoffClient) -> SchedulingHandoffFlow {
        let log = Logger(subsystem: "com.distronode.district", category: "SchedulingHandoff")
        return SchedulingHandoffFlow(
            client: client,
            newState: { PKCE.newState() },
            log: { line in log.info("\(line, privacy: .public)") }
        )
    }
}
