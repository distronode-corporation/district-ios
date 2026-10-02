import DistrictAuthCore
import Foundation

/// The installation id sent as `deviceId` on token exchange.
///
/// ⛔ `UserDefaults`, NOT THE KEYCHAIN, AND THAT IS DELIBERATE. A Keychain item
/// survives app deletion, so a reinstall would keep presenting the same device
/// id and the server would treat the fresh install as the SAME device — merging
/// it with a session the user may have signed out of from the settings device
/// list. `UserDefaults` is wiped with the app, which is exactly what "this is a
/// new installation" should mean.
///
/// ⚠️ IT IS NOT A DEVICE FINGERPRINT AND MUST NOT BECOME ONE. The server treats
/// it as opaque and uses it only to scope per-device sign-out; anything derived
/// from hardware would be a stable cross-install identifier, which is both a
/// privacy claim we do not make and an App Store review question.
enum DeviceIdentity {
    static let defaultsKey = "com.distronode.district.deviceId"

    static func current(defaults: UserDefaults = .standard) -> String {
        // The route's schema is `z.string().min(8).max(200)`; a UUID string is 36
        // characters. The length check also discards a value truncated by an
        // earlier bug rather than sending one the server would 400.
        if let existing = defaults.string(forKey: defaultsKey), existing.count >= 8 {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: defaultsKey)
        return fresh
    }
}

/// ``InstallationLedger`` over `UserDefaults`, for the reason ``DeviceIdentity`` is
/// there too: it is erased with the app, and the Keychain is not.
///
/// ⛔ "FRESH INSTALL" IS READ OFF THE DEVICE ID'S ABSENCE, SO ``begin(defaults:)`` MUST
/// RUN BEFORE ``DeviceIdentity/current(defaults:)``, which mints one. A dedicated
/// "first launch" key would read as absent on every EXISTING installation the first
/// time a build carrying this code runs, and would sign every current user out on
/// update. Every signed-in installation has a device id, because the token exchange
/// sends one, so its absence can only wipe a store that holds no session of this
/// installation's own.
///
/// ⚠️ THE OWED FLAG IS ITS OWN KEY, NOT "THE DEVICE ID IS MISSING" READ AGAIN LATER,
/// because the id is minted in the same launch: a wipe that failed (a store that
/// would not answer) must still be owed on the next launch, by which time the id
/// exists.
final class UserDefaultsInstallationLedger: InstallationLedger, @unchecked Sendable {
    static let owedKey = "com.distronode.district.previousInstallWipeOwed"

    private let defaults: UserDefaults

    private init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Raise the owed flag if this is the first run of this installation, and
    /// return the ledger. ⛔ Before ``DeviceIdentity/current(defaults:)``; see the type.
    static func begin(defaults: UserDefaults = .standard) -> UserDefaultsInstallationLedger {
        if defaults.string(forKey: DeviceIdentity.defaultsKey) == nil {
            defaults.set(true, forKey: owedKey)
        }
        return UserDefaultsInstallationLedger(defaults: defaults)
    }

    var owesPreviousInstallWipe: Bool {
        defaults.bool(forKey: Self.owedKey)
    }

    func settle() {
        defaults.removeObject(forKey: Self.owedKey)
    }
}
