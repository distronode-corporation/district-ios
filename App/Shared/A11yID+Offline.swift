/// The offline banner, so a UI test can tell the saved copy from a live one.
///
/// ⚠️ NO KOTLIN TWIN: Android has no offline copy yet. If it gains one, the two should
/// share this string.
extension A11yID {
    enum Offline {
        static let banner = "district-offline-banner"
    }
}
