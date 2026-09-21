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
