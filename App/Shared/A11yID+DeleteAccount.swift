/// The in-app account deletion sheet (Account, Delete account).
///
/// ⚠️ NO KOTLIN TWIN YET: Android still hands deletion to its page. If it gains the same
/// flow, the two should share these strings.
extension A11yID {
    enum DeleteAccount {
        static let sheet = "district-delete-account-sheet"
        static let cancel = "district-delete-account-cancel"
        static let message = "district-delete-account-message"
        static let usePassword = "district-delete-account-use-password"
        /// One button per provider, keyed by its wire name (`google`, `azure-ad`, `apple`).
        static func provider(_ wire: String) -> String {
            "district-delete-account-provider-\(wire)"
        }

        static let password = "district-delete-account-password"
        static let code = "district-delete-account-code"
        static let passwordContinue = "district-delete-account-password-continue"
        static let back = "district-delete-account-back"
        static let email = "district-delete-account-email"
        /// ⛔ A FORBIDDEN SURFACE: deletes the signed-in account. Only the loopback
        /// `DeleteAccountScreenshotTests` presses it.
        static let submit = "district-delete-account-submit"
    }
}
