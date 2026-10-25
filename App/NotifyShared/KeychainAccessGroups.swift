import Foundation

/// The two Keychain access groups, named explicitly on every query that touches them.
///
/// ⛔ PRIVATE AND SHARED, AND NOTHING SECRET IS EVER WRITTEN WITHOUT ONE OF THEM NAMED. The
/// app's entitlement lists the private group first and the shared `.notify` group second
/// (project.yml), and a write with no group lands in the first one listed: correct today,
/// one reordered line away from putting the session where the notification service
/// extension can read it. So ``KeychainTokenStore`` names ``privateGroup`` and
/// ``NotifyTokenKeychain`` names ``notifyGroup``, and the archive script refuses a signature
/// whose first group is not the private one.
///
/// ⚠️ THE PRIVATE GROUP IS THE APP'S APPLICATION IDENTIFIER, the group every item it ever
/// wrote already sits in, so naming it moves nothing and signs nobody out.
///
/// ⚠️ nil ON AN UNSIGNED BUILD. The team prefix reaches the bundle through the Info.plist key
/// below, resolved from `$(AppIdentifierPrefix)` at build time, which is empty without a
/// signing team. Then no group is named: the session store behaves as it did before 3.2
/// (an unsigned simulator build has no Keychain access anyway), and the notify store
/// refuses to read or write at all.
enum KeychainAccessGroups {
    static let infoKey = "DistrictAppIdentifierPrefix"
    static let privateSuffix = "com.distronode.district"
    static let notifySuffix = "com.distronode.district.notify"

    static var privateGroup: String? {
        group(privateSuffix, prefix: bundlePrefix)
    }

    static var notifyGroup: String? {
        group(notifySuffix, prefix: bundlePrefix)
    }

    /// The group, or nil when the prefix is not a resolved team prefix ("R935BA6767.").
    /// ⚠️ An unsubstituted `$(...)` is refused like an empty one.
    static func group(_ suffix: String, prefix: String?) -> String? {
        guard let prefix, prefix.count > 1, prefix.hasSuffix("."), !prefix.contains("$(") else { return nil }
        return prefix + suffix
    }

    private static var bundlePrefix: String? {
        Bundle.main.object(forInfoDictionaryKey: infoKey) as? String
    }
}
