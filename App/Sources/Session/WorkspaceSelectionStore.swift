import Foundation

/// Where this device remembers which workspace the user is working in.
///
/// ⛔ THIS IS THE NATIVE EQUIVALENT OF A COOKIE THE APP CANNOT HOLD. On the web the
/// active workspace is `distronode_workspace_id`, httpOnly, which the server's tenant
/// listers promote to index 0 so that every `requireWorkspaceRole` fallback resolves
/// to it. A bearer-token client sends no cookies, so `POST
/// /api/district/workspace/select` would set a cookie this app immediately discards.
/// The selection therefore lives here and is sent explicitly as `workspaceId` on
/// every request, which the server re-validates against live membership.
///
/// ⚠️ THE STORED VALUE IS A HINT AND IS NOT TRUSTED. It is an id the user chose
/// earlier; by the time it is read they may have been removed from that workspace or
/// its subscription may have lapsed. ``WorkspaceSessionModel`` only ever adopts it
/// after confirming it still appears in the server's own list.
///
/// ⛔ `UserDefaults`, NOT THE KEYCHAIN, AND THAT IS DELIBERATE RATHER THAN LAZY. A
/// workspace id is not a credential: knowing one grants nothing without a token that
/// is a member of it. The Android client keeps it in plain `SharedPreferences` for
/// the same reason. Contrast `KeychainTokenStore`, which holds something that IS a
/// credential and carries `kSecAttrSynchronizable = false` because of it.
///
/// ⛔ CLEARED ON SIGN-OUT, WHICH IS NOT ABOUT SECRECY. Leaving it means the next user
/// of a shared device lands in the previous user's workspace by default. Android
/// asserts exactly this in `AppContainerTest`; here it is ``SessionModel/signOut()``
/// that does it.
struct WorkspaceSelectionStore {
    /// ⚠️ Namespaced like `DeviceIdentity.defaultsKey`, so the two values in this
    /// app's defaults domain cannot be confused for anything the system wrote.
    static let defaultsKey = "com.distronode.district.selectedWorkspaceId"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The id the user last chose on this device, or nil if they never have.
    func selectedWorkspaceId() -> String? {
        defaults.string(forKey: Self.defaultsKey)
    }

    /// Remember a choice. Passing nil forgets it, returning to the server's own
    /// ordering on the next load.
    func setSelectedWorkspaceId(_ workspaceId: String?) {
        guard let workspaceId else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        defaults.set(workspaceId, forKey: Self.defaultsKey)
    }
}
