import Foundation

/// The words of the authenticator-code step after Sign in with Apple.
///
/// ⚠️ ENGLISH CONSTANTS IN ONE PLACE, AS ``SessionCopy`` AND ``SignInCopy`` ARE: the app
/// is English only, and a single home is what a later localisation pass replaces.
///
/// ⛔ ``expired`` TELLS THE PERSON WHAT TO DO, because it is the one refusal no amount
/// of typing can fix: the ticket is gone and only a fresh Apple sign-in mints another.
/// ``SignInStatusTone`` colours it as a warning on the sign-in screen.
enum MfaCopy {
    static let title = "Enter your code"
    static let authenticatorPrompt = "Your account uses an authenticator app. "
        + "Enter the 6-digit code it shows for District AI."
    static let recoveryPrompt = "Enter one of the recovery codes you saved when you set up "
        + "your authenticator app. Each code works once."
    static let authenticatorPlaceholder = "6-digit code"
    static let recoveryPlaceholder = "Recovery code"
    static let useRecovery = "Use a recovery code instead"
    static let useAuthenticator = "Use your authenticator app instead"
    static let verify = "Verify"
    static let cancel = "Cancel"

    static let wrongCode = "That code did not work. Check the code and try again."
    static let expired = "That sign-in timed out. Sign in with Apple again."
}
