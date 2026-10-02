import Foundation

/// Every sentence ``SessionModel`` puts in ``AuthPhase``, named once.
///
/// ⛔ ONE HOME BECAUSE TWO READERS KEY ON THE EXACT TEXT. ``SessionModel`` writes these
/// into the phase, and ``SignInStatusTone`` colours the status by matching them; when the
/// tone sets held hand-copied sentences, a rewording here silently demoted a message to
/// neutral. Both now read these constants, so a rewording moves both together.
///
/// ⚠️ ``SignInCopy/noAccount`` STAYS IN `SignInCopy`: it is the server's sentence, pinned
/// word for word against the route, not one of the session's own.
enum SessionCopy {
    // MARK: - Sign-in outcomes

    static let signInNotVerified = "That sign-in could not be verified. Please try again."
    static let signInExpired = "That sign-in expired. Please try again."
    static let tooManyAttempts = "Too many attempts. Please try again shortly."
    static let unreachable = "We could not reach District AI. Check your connection."

    /// ⚠️ NEUTRAL ON PURPOSE (it is in no tone set): the reason could be anything from a
    /// cancelled consent screen to a policy refusal, a severity this client cannot judge.
    static func signInNotCompleted(_ reason: String) -> String {
        "Sign-in was not completed (\(reason))."
    }

    static let signedOut = "You are signed out."

    // MARK: - Reauthentication reasons

    /// ⛔ NOT A SECURITY EVENT, AND MUST NEVER BE WORDED AS ONE. It means the app was
    /// killed mid-refresh, so the stored token is presumed spent. The server accepts that
    /// this costs a re-login; the wording should too.
    static let interruptedRefresh = "Your session ended unexpectedly. Please sign in again."
    static let refreshTokenExpired = "You have been signed out after 60 days. Please sign in again."
    static let refreshRejected = "Your session is no longer valid. Please sign in again."
    static let refreshUnreachable = "We could not confirm your session. Please sign in again."

    // MARK: - Retry reasons

    static let refreshThrottled = "Too many requests. Please try again shortly."
    static let refreshNotSent = "You appear to be offline. Your session is still active."
    /// The Keychain read failed, typically because the device is locked.
    static let storeUnavailable = "We could not read your saved session. Please try again."
    static let markerNotDurable = "We could not safely refresh your session. Please try again."
}
