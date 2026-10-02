@testable import DistrictAI
import DistrictAuthCore
import Foundation
import XCTest

/// What the container does with a refused bearer, and how a reinstall is recognised.
///
/// ⚠️ IN THE APP SUITE BECAUSE BOTH HALVES ARE APP-SIDE WIRING: the closure `api` is
/// built with, and the `UserDefaults` ledger ``FreshInstallTokenStore`` consults. The
/// decisions themselves are tested in the package.
final class SessionCredentialWiringTests: XCTestCase {
    // MARK: - A 401 invalidates exactly the refused token

    /// ⚠️ `@MainActor` because ``AppContainer`` is, and with it its static helpers.
    @MainActor
    func testARejectedBearerMakesTheNextCallRefresh() async {
        let refresh = CountingRefreshClient()
        let coordinator = TokenRefreshCoordinator(store: InMemoryTokenStore(), refreshClient: refresh)
        let farFuture = Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000
        await coordinator.adopt(
            NativeTokens(
                accessToken: "access-1",
                accessTokenExpiresAt: farFuture,
                refreshToken: "refresh-1",
                refreshTokenExpiresAt: farFuture
            ),
            deviceId: "device-test"
        )
        let rejected = AppContainer.rejected(coordinator)

        // ⛔ A LATE REPORT ABOUT SOME OTHER TOKEN MUST NOT DISCARD THE CURRENT ONE.
        await rejected("access-stale")
        let kept = await coordinator.accessToken()
        XCTAssertEqual(kept, .available("access-1"))
        let untouched = await refresh.calls
        XCTAssertEqual(untouched, 0)

        await rejected("access-1")
        _ = await coordinator.accessToken()
        let refreshed = await refresh.calls
        XCTAssertEqual(refreshed, 1, "the refused token is dropped, so the next call refreshes")
    }

    // MARK: - A fresh install owes a wipe; an update does not

    func testAFreshInstallOwesAWipeUntilSettled() throws {
        let defaults = try makeDefaults()

        let ledger = UserDefaultsInstallationLedger.begin(defaults: defaults)
        _ = DeviceIdentity.current(defaults: defaults)

        XCTAssertTrue(ledger.owesPreviousInstallWipe)
        // ⚠️ STILL OWED ON THE NEXT LAUNCH if this one could not wipe, even though the
        // device id now exists.
        XCTAssertTrue(UserDefaultsInstallationLedger.begin(defaults: defaults).owesPreviousInstallWipe)

        ledger.settle()
        XCTAssertFalse(UserDefaultsInstallationLedger.begin(defaults: defaults).owesPreviousInstallWipe)
    }

    /// ⛔ AN EXISTING INSTALLATION UPDATING TO THIS BUILD OWES NOTHING. Its device id
    /// is already in defaults; treating it as fresh would sign every user out.
    func testAnExistingInstallationOwesNothing() throws {
        let defaults = try makeDefaults()
        _ = DeviceIdentity.current(defaults: defaults)

        XCTAssertFalse(UserDefaultsInstallationLedger.begin(defaults: defaults).owesPreviousInstallWipe)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "SessionCredentialWiringTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}

/// A ``RefreshClient`` that counts and refuses to rotate.
private actor CountingRefreshClient: RefreshClient {
    private(set) var calls = 0

    func refresh(refreshToken _: String) async -> RefreshResult {
        calls += 1
        return .rateLimited
    }
}
