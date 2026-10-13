import DistrictL10n
import Foundation

/// The test bundle's principal class (`NSPrincipalClass`, set in project.yml), created by
/// XCTest when it loads the bundle and before any test runs.
///
/// ⛔ EVERY TEST IN THIS BUNDLE READS ENGLISH, WHATEVER THE SIMULATOR IS SET TO. Hundreds
/// of assertions compare against English sentences, and the host app, launched first,
/// sets the language from the device (``AppL10n/bootstrap()``). A run on a French
/// simulator of a build that ships French would otherwise fail every one of them for a
/// reason that has nothing to do with the code under test. A test that wants French asks
/// for it in its own scope with ``L10nRuntime/withLocale(_:_:)``, which leaves this alone.
final class EnglishTestLocale: NSObject {
    override init() {
        L10nRuntime.locale = .en
        super.init()
    }
}
