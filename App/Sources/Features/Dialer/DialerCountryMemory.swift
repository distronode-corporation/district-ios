import Foundation

/// What the dialler remembers about a workspace's country between launches.
///
/// ⚠️ TWO FACTS, KEPT APART. The HOME country is derived from the workspace's own numbers
/// (``DialerModel/homeCountry(fromNumbers:)``) and cached so the keypad opens on the right
/// flag before the numbers have loaded. The PICKED country is what the operator chose on a
/// workspace with no home country, so that "pick it once" holds: the next dial starts
/// there. A home country, once known, wins over a pick.
///
/// ⚠️ NOT A SERVER FIELD, ON PURPOSE. Adding a country to an API response would change the
/// mobile contracts; everything here is read from what the app already receives.
protocol DialerCountryMemory {
    func home(workspaceId: String) -> String?
    func rememberHome(_ iso: String, workspaceId: String)
    func picked(workspaceId: String) -> String?
    func rememberPicked(_ iso: String, workspaceId: String)
}

/// ``DialerCountryMemory`` over `UserDefaults`.
///
/// ⚠️ `UserDefaults` FOR THE REASON ``UserDefaultsPushTokenMemory`` GIVES: it is wiped with
/// the app. A country code is not a secret, and a stale one costs one tap on the picker.
///
/// ⛔ A STORED VALUE IS CHECKED AGAINST THE TABLE ON READ, so a code this version does not
/// list (or a corrupted default) reads as "no country" rather than a flag with no number.
final class UserDefaultsDialerCountryMemory: DialerCountryMemory, @unchecked Sendable {
    /// ⚠️ NAMESPACED like ``UserDefaultsPushTokenMemory/defaultsKey``, then the workspace.
    static let homeKeyPrefix = "com.distronode.district.dialer.homeCountry."
    static let pickedKeyPrefix = "com.distronode.district.dialer.pickedCountry."

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func home(workspaceId: String) -> String? {
        known(defaults.string(forKey: Self.homeKeyPrefix + workspaceId))
    }

    func rememberHome(_ iso: String, workspaceId: String) {
        defaults.set(iso, forKey: Self.homeKeyPrefix + workspaceId)
    }

    func picked(workspaceId: String) -> String? {
        known(defaults.string(forKey: Self.pickedKeyPrefix + workspaceId))
    }

    func rememberPicked(_ iso: String, workspaceId: String) {
        defaults.set(iso, forKey: Self.pickedKeyPrefix + workspaceId)
    }

    private func known(_ iso: String?) -> String? {
        guard let iso, DialPlan.callingCode(for: iso) != nil else { return nil }
        return iso
    }
}
