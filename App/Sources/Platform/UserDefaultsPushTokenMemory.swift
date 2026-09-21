import DistrictData
import Foundation

/// Where the last push token the server AFFIRMED is kept between launches.
///
/// ⛔ `UserDefaults`, NOT THE KEYCHAIN, AND FOR THE SAME REASON ``DeviceIdentity``
/// USES IT. A Keychain item survives app deletion, so a reinstall would come back
/// claiming to have already registered a token the fresh install does not hold —
/// and ``PushTokenRepository`` would then SKIP the register, leaving push silently
/// off for the life of that install. Defaults are wiped with the app, which is
/// exactly what "this is a new installation" should mean.
///
/// ⛔ AND IT IS NOT A CREDENTIAL OF OURS. An APNs device token authorises sending
/// TO one installation and is useless without the Firebase service account, so it
/// is stored as issued rather than hashed — we have to be able to replay it. It
/// still identifies one handset, so it is never logged and never put in an error
/// message.
///
/// ⚠️ EVERY DECISION TAKEN FROM THIS VALUE LIVES IN ``PushTokenRepository``, on the
/// tier that has tests. This type is the three `UserDefaults` calls and nothing
/// else, deliberately: `App/` is the one tier with no test lane, so the less it
/// decides, the better.
///
/// ⚠️ `@unchecked Sendable` BECAUSE `UserDefaults` IS DOCUMENTED THREAD-SAFE and
/// this type adds no state of its own beyond the reference to it.
final class UserDefaultsPushTokenMemory: PushTokenMemory, @unchecked Sendable {
    /// ⚠️ NAMESPACED THE SAME WAY ``DeviceIdentity/defaultsKey`` IS. Defaults are a
    /// flat namespace shared with every framework the app links.
    static let defaultsKey = "com.distronode.district.pushToken"

    /// ⛔ A SECOND KEY, NOT A SECOND USE OF THE FIRST. One handset holds two push
    /// tokens — APNs issues the alert one and PushKit the ring one — and they
    /// rotate independently. Sharing a slot would make the VoIP register skip
    /// because the ALERT token was unchanged, and the phone would stop ringing with
    /// nothing anywhere reporting it.
    static let voipDefaultsKey = "com.distronode.district.voipPushToken"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func lastRegisteredToken() -> String? {
        defaults.string(forKey: Self.defaultsKey)
    }

    func rememberRegisteredToken(_ token: String) {
        defaults.set(token, forKey: Self.defaultsKey)
    }

    func forgetRegisteredToken() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    func lastRegisteredVoipToken() -> String? {
        defaults.string(forKey: Self.voipDefaultsKey)
    }

    func rememberRegisteredVoipToken(_ token: String) {
        defaults.set(token, forKey: Self.voipDefaultsKey)
    }

    func forgetRegisteredVoipToken() {
        defaults.removeObject(forKey: Self.voipDefaultsKey)
    }
}
