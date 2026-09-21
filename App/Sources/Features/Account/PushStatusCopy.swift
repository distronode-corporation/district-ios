/// What the Account screen says about notifications on THIS device.
///
/// ⛔ IT NAMES THE REMEDY, NOT THE FAULT. Every line below either says the thing is
/// working or tells the reader what to do next, because the states this reports are
/// ones only they can clear: a permission lives in iOS Settings, a stale session
/// needs a sign-in, and a refusal from the server needs support. "Registration
/// failed" would be true, unactionable, and exactly as useless as the silence this
/// replaces.
///
/// ⚠️ AUTHORIZATION AND REGISTRATION ARE BOTH REQUIRED TO SAY ANYTHING TRUE.
/// Permission granted with a refused registration, and permission denied having
/// never tried, are indistinguishable from either value alone.
enum PushStatusCopy {
    static let title = "Notifications"

    static func subtitle(
        authorization: PushAuthorization,
        registration: PushRegistrationStatus
    ) -> String {
        switch authorization {
        case .notAsked:
            "Not set up on this device yet."
        case .denied:
            "Turned off. Allow notifications for District AI in iOS Settings "
                + "to receive calls and messages."
        case .unavailable:
            "This device could not be asked for permission. Try again, or restart the app."
        case .authorized:
            authorizedSubtitle(registration)
        }
    }

    /// ⚠️ PERMISSION GRANTED IS THE HALFWAY POINT, NOT THE ANSWER. Four of these five
    /// states are "allowed, and still will not ring", which is precisely the gap that
    /// goes unnoticed when only the permission is reported.
    private static func authorizedSubtitle(_ registration: PushRegistrationStatus) -> String {
        switch registration {
        case .notAttempted:
            "Allowed. Setting up this device."
        case .registered:
            "Allowed. This device is set up to receive calls and messages."
        case .apnsRefused:
            "Allowed, but Apple did not issue a token for this device. "
                + "Restart the app; if it persists, contact support."
        case .unreachable:
            "Allowed, but this device could not reach District AI. Check your connection."
        case let .refused(status):
            refusedSubtitle(status)
        }
    }

    /// ⛔ THE STATUS IS TRANSLATED, NOT PRINTED. A person reading "HTTP 429" learns
    /// nothing; a person reading "too many attempts, try again shortly" knows whether
    /// to wait or to call somebody. ⚠️ The number is still appended for the three
    /// codes that have no specific remedy, because a support conversation about an
    /// unexplained refusal needs it.
    private static func refusedSubtitle(_ status: Int) -> String {
        switch status {
        case 401, 403:
            "Allowed, but your session has expired. Sign out and sign in again."
        case 429:
            "Allowed, but too many attempts were made. This will retry shortly."
        default:
            "Allowed, but District AI refused to set up this device (error \(status)). "
                + "Contact support if it continues."
        }
    }
}
