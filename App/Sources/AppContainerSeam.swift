import DistrictAuthCore
import Foundation

/// Where ``AppContainer`` gets its token store, device id and base URL from.
///
/// ⛔ IT IS ITS OWN FILE BECAUSE `AppContainer.swift` SITS AGAINST THE `file_length`
/// CEILING `swiftlint --strict` PROMOTES TO AN ERROR, AND ITS INITIALISER AGAINST THE
/// 60-LINE `function_body_length` LIMIT, so a seam of any size would break both. In
/// this project, check `wc -l` before planning an edit. The container spends two lines
/// here rather than twenty.
///
/// ⛔ THE `#if DEBUG` LIVES IN HERE, WHICH IS THE SECURITY BOUNDARY AND NOT A TIDYING.
/// Measured on this project rather than taken from XcodeGen's documentation:
/// `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` appears exactly once in the generated
/// `project.pbxproj`, and `xcodebuild -showBuildSettings` resolves it in **Debug** and
/// reports it **absent** in **Release**. A Release build therefore contains no branch
/// that can reach ``UITestSession`` at all, and `archive-imac.sh` re-proves it per
/// archive with `strings … | grep -c 'DISTRICT_UITEST'` = 0.
enum AppContainerSeam {
    /// What the container should actually use.
    struct Resolved {
        let store: any TokenStore
        let deviceId: String
        let baseURL: URL

        /// ⚠️ A CLOSURE RATHER THAN A FLAG, so the container calls one thing and the
        /// Release build calls a no-op. Nothing at the call site branches on whether
        /// a test session exists, which is what keeps the container honest.
        let adopt: (TokenRefreshCoordinator) -> Void
    }

    /// ⚠️ THE PRODUCTION ANSWER IS THE DEFAULT AND THE ONLY ONE IN RELEASE: the
    /// Keychain store, this installation's real device id, and the caller's base URL.
    static func resolve(baseURL: URL) -> Resolved {
        #if DEBUG
            if let injected = UITestSession.current() {
                return Resolved(
                    // ⚠️ IN MEMORY, NEVER THE KEYCHAIN, so a UI-test run leaves no
                    // credential on a handset that is somebody's own phone.
                    store: InMemoryTokenStore(),
                    deviceId: injected.deviceId,
                    baseURL: injected.baseURL ?? baseURL,
                    // ⛔ ONE mint, ONE launch. Refresh rotation is single-use: a
                    // replay is read as theft and revokes the whole family.
                    adopt: { coordinator in
                        Task { await coordinator.adopt(injected.tokens, deviceId: injected.deviceId) }
                    }
                )
            }
            if UITestSession.isArmed() {
                // ⚠️ ARMED, NO SESSION: the unauthenticated UI lane. An EMPTY
                // in-memory store is a fresh install's state, so the gate renders
                // the real signed-out screen instead of the Keychain-unreadable
                // one an unsigned simulator build always lands on. See
                // ``UITestSession/isArmed(arguments:)``.
                return Resolved(
                    store: InMemoryTokenStore(),
                    deviceId: DeviceIdentity.current(),
                    baseURL: baseURL,
                    adopt: { _ in }
                )
            }
        #endif
        return Resolved(
            store: KeychainTokenStore(),
            deviceId: DeviceIdentity.current(),
            baseURL: baseURL,
            adopt: { _ in }
        )
    }
}
