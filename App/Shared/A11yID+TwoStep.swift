/// The two-step verification sheet (Account, Two-step verification).
///
/// ⚠️ NO KOTLIN TWIN YET: Android has no such screen. If it gains one, the two should share
/// these strings.
extension A11yID {
    enum TwoStep {
        static let sheet = "district-two-step-sheet"
        static let close = "district-two-step-close"
        static let retry = "district-two-step-retry"
        static let status = "district-two-step-status"
        static let notice = "district-two-step-notice"
        static let message = "district-two-step-message"
        static let turnOn = "district-two-step-turn-on"
        /// ⛔ A FORBIDDEN SURFACE once past the re-authentication: it turns the factor off.
        static let turnOff = "district-two-step-turn-off"
        static let usePassword = "district-two-step-use-password"
        /// One button per provider, keyed by its wire name (`google`, `azure-ad`, `apple`).
        static func provider(_ wire: String) -> String {
            "district-two-step-provider-\(wire)"
        }

        static let password = "district-two-step-password"
        static let code = "district-two-step-code"
        static let passwordContinue = "district-two-step-password-continue"
        static let back = "district-two-step-back"
        static let qr = "district-two-step-qr"
        static let secret = "district-two-step-secret"
        static let copyKey = "district-two-step-copy-key"
        static let openAuthenticator = "district-two-step-open-authenticator"
        static let totp = "district-two-step-totp"
        /// ⛔ A FORBIDDEN SURFACE: turns the factor on for the signed-in account.
        static let confirm = "district-two-step-confirm"
        static let codes = "district-two-step-codes"
        static let copyCodes = "district-two-step-copy-codes"
        static let codesDone = "district-two-step-codes-done"
    }
}
