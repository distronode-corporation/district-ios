import Foundation

/// Whether this installation still owes a wipe of a session an EARLIER one left.
///
/// ⛔ THE ANSWER HAS TO LIVE SOMEWHERE APP DELETION ERASES, WHICH THE TOKEN STORE
/// IS NOT. The production store is the Keychain, and a Keychain item survives the
/// app being deleted: a reinstall used to find the previous user's refresh token
/// and sign them straight back in, on a device they may have handed on. The app
/// implements this over `UserDefaults`, which goes with the app, the same
/// reasoning `DeviceIdentity` already relies on.
///
/// ⚠️ "OWED", NOT "FIRST LAUNCH". The flag is raised once, on the launch that
/// finds no trace of an earlier run of THIS installation, and stays raised until
/// ``settle()`` is called after the wipe has actually happened. A launch that
/// could not wipe (a store that would not answer) therefore tries again next
/// time instead of reading the old session on the second launch.
public protocol InstallationLedger: Sendable {
    /// True until a wipe of the previous installation's session has completed.
    var owesPreviousInstallWipe: Bool { get }

    /// Record that the wipe completed. Called once, after the store is clear.
    func settle()
}

/// A ``TokenStore`` that clears a previous installation's session before anything
/// can read it.
///
/// ⛔ A DECORATOR RATHER THAN A STEP AT LAUNCH, BECAUSE "BEFORE ANYTHING READS IT"
/// IS THE WHOLE REQUIREMENT. Every member waits for the wipe first, so no ordering
/// between the container's construction, the session gate's first read and the
/// launch drain has to be got right. The wipe runs once; each later call costs a
/// `Bool` read.
///
/// ⛔ THE OLD REFRESH TOKEN GOES TO THE REVOKE OUTBOX, NOT TO THE NETWORK. Nothing
/// here may hold up the first screen, and the launch drain
/// (``SignOutCoordinator/drainPendingRevoke()``) presents the outbox moments later
/// on the same launch. ⚠️ If the outbox already holds an entry, the old session's
/// token replaces it: one slot cannot hold two live credentials, and the session's
/// is the newer, so it has the longer remaining life (see ``RevokeOutbox``).
///
/// ⚠️ A FAILED OUTBOX WRITE STILL WIPES, and a failed read or wipe throws. The
/// first follows ``SignOutCoordinator``: leaving the previous user signed in is the
/// worse failure. The second is ``TokenStore``'s own rule: a thrown read is
/// "could not check", which the coordinator reports as
/// ``RetryReason/storeUnavailable`` rather than as either answer, and the ledger
/// stays owed so the next call tries again.
public actor FreshInstallTokenStore: TokenStore {
    private let base: any TokenStore
    private let ledger: any InstallationLedger
    private var wiping: Task<Void, any Error>?

    public init(base: any TokenStore, ledger: any InstallationLedger) {
        self.base = base
        self.ledger = ledger
    }

    public func read() async throws -> PersistedSession? {
        try await settle()
        return try await base.read()
    }

    public func write(_ session: PersistedSession) async throws {
        try await settle()
        try await base.write(session)
    }

    public func clear() async throws {
        try await settle()
        try await base.clear()
    }

    public func pendingRefreshToken() async throws -> String? {
        try await settle()
        return try await base.pendingRefreshToken()
    }

    public func markRefreshPending(_ refreshToken: String) async throws {
        try await settle()
        try await base.markRefreshPending(refreshToken)
    }

    public func clearRefreshPending() async throws {
        try await settle()
        try await base.clearRefreshPending()
    }

    public func pendingRevokeToken() async throws -> String? {
        try await settle()
        return try await base.pendingRevokeToken()
    }

    public func markRevokePending(_ refreshToken: String) async throws {
        try await settle()
        try await base.markRevokePending(refreshToken)
    }

    public func clearRevokePending() async throws {
        try await settle()
        try await base.clearRevokePending()
    }

    // ── Internals ────────────────────────────────────────────────────────────

    /// ⚠️ ONE WIPE, HOWEVER MANY CALLERS ARRIVE DURING IT. This actor suspends at
    /// every `await`, so two first calls would otherwise both read and both wipe.
    private func settle() async throws {
        guard ledger.owesPreviousInstallWipe else { return }
        let task = wiping ?? Task { [base, ledger] in
            if let stale = try await base.read() {
                try? await base.markRevokePending(stale.refreshToken)
            }
            try await base.clear()
            ledger.settle()
        }
        wiping = task
        defer { wiping = nil }
        try await task.value
    }
}
