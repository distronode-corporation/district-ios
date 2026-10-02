@testable import DistrictAuthCore
import Foundation
import XCTest

/// A reinstall must not resume the previous installation's session.
///
/// ⛔ THE PROPERTY UNDER TEST IS "NOTHING READS THE OLD SESSION". The Keychain
/// survives app deletion, so before this store existed a reinstall handed the
/// previous user's refresh token straight to the coordinator and signed them back
/// in. Each case below is one way that could still happen: a read before the
/// wipe, a wipe that silently failed and was recorded as done, or an old token
/// dropped untracked instead of revoked.
final class FreshInstallTokenStoreTests: XCTestCase {
    func testAnOwedWipeHidesTheOldSessionAndQueuesItsRevoke() async {
        let base = InMemoryTokenStore(session: AuthFixtures.session(refreshToken: "previous-user"))
        let ledger = TestLedger(owed: true)
        let store = FreshInstallTokenStore(base: base, ledger: ledger)

        await expectNil("the previous installation's session must not be readable") {
            try? await store.read()
        }
        await expectEqual("previous-user", "and its token is queued for the launch drain") {
            try? await store.pendingRevokeToken()
        }
        XCTAssertFalse(ledger.owesPreviousInstallWipe)
    }

    /// ⛔ THE COORDINATOR, NOT ONLY THE STORE: a reinstall has to land on the
    /// sign-in screen, with no refresh attempted on the old token.
    func testTheCoordinatorSeesNoSessionAfterAReinstall() async {
        let base = InMemoryTokenStore(session: AuthFixtures.session())
        let store = FreshInstallTokenStore(base: base, ledger: TestLedger(owed: true))
        let client = NeverRefreshClient()
        let coordinator = TokenRefreshCoordinator(store: store, refreshClient: client, now: { AuthFixtures.now })

        await expectEqual(AccessTokenOutcome.reauthRequired(.noSession)) { await coordinator.accessToken() }
        await expectEqual(0) { await client.callCount }
    }

    /// ⚠️ AN EXISTING INSTALLATION IS UNTOUCHED. An update must not sign anyone out.
    func testNothingIsWipedWhenNothingIsOwed() async {
        let live = AuthFixtures.session()
        let base = SpyTokenStore(session: live)
        let store = FreshInstallTokenStore(base: base, ledger: TestLedger(owed: false))

        await expectEqual(Optional(live)) { try? await store.read() }
        await expectEqual([.read]) { await base.operations }
    }

    /// ⛔ A STORE THAT CANNOT BE READ IS "COULD NOT CHECK", NOT "NOTHING THERE". The
    /// call throws, the ledger stays owed, and the next call wipes for real.
    func testAFailedReadThrowsAndLeavesTheWipeOwed() async {
        let base = SpyTokenStore(session: AuthFixtures.session())
        await base.failReads(true)
        let ledger = TestLedger(owed: true)
        let store = FreshInstallTokenStore(base: base, ledger: ledger)

        do {
            _ = try await store.read()
            XCTFail("a thrown read must not be reported as no session")
        } catch {}
        XCTAssertTrue(ledger.owesPreviousInstallWipe)

        await base.failReads(false)
        await expectNil { try? await store.read() }
        await expectNil { await base.session }
        XCTAssertFalse(ledger.owesPreviousInstallWipe)
    }

    /// ⚠️ A FAILED OUTBOX WRITE STILL WIPES. Leaving the previous user signed in is
    /// the worse of the two failures, which is the same call sign-out makes.
    func testAFailedOutboxWriteStillWipes() async {
        let base = SpyTokenStore(session: AuthFixtures.session())
        await base.failRevokeMarkerWrites(true)
        let ledger = TestLedger(owed: true)
        let store = FreshInstallTokenStore(base: base, ledger: ledger)

        await expectNil { try? await store.read() }
        await expectNil { await base.session }
        XCTAssertFalse(ledger.owesPreviousInstallWipe)
    }

    /// ⚠️ THE NEWER TOKEN TAKES THE ONE SLOT. See ``RevokeOutbox``.
    func testTheOldSessionReplacesAnOlderOutboxEntry() async {
        let base = SpyTokenStore(session: AuthFixtures.session(refreshToken: "newer"), revokePending: "older")
        let store = FreshInstallTokenStore(base: base, ledger: TestLedger(owed: true))

        await expectEqual("newer") { try? await store.pendingRevokeToken() }
    }

    /// Every member reaches the store it wraps once the wipe is done.
    func testEveryMemberPassesThroughAfterTheWipe() async throws {
        let base = InMemoryTokenStore()
        let store = FreshInstallTokenStore(base: base, ledger: TestLedger(owed: true))

        try await store.write(AuthFixtures.session(refreshToken: "fresh"))
        await expectEqual("fresh") { try? await base.read()?.refreshToken }
        try await store.markRefreshPending("fresh")
        await expectEqual("fresh") { try? await store.pendingRefreshToken() }
        try await store.clearRefreshPending()
        await expectNil { try? await base.pendingRefreshToken() }
        try await store.markRevokePending("gone")
        await expectEqual("gone") { try? await base.pendingRevokeToken() }
        try await store.clearRevokePending()
        await expectNil { try? await base.pendingRevokeToken() }
        try await store.clear()
        await expectNil { try? await base.read() }
    }
}

/// An ``InstallationLedger`` the tests set by hand.
private final class TestLedger: InstallationLedger, @unchecked Sendable {
    private let lock = NSLock()
    private var owed: Bool

    init(owed: Bool) {
        self.owed = owed
    }

    var owesPreviousInstallWipe: Bool {
        lock.withLock { owed }
    }

    func settle() {
        lock.withLock { owed = false }
    }
}
