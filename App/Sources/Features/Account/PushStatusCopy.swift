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
    static func subtitle(
        authorization: PushAuthorization,
        registration: PushRegistrationStatus
    ) -> String {
        switch authorization {
        case .notAsked:
            notAsked
        case .denied:
            denied
        case .unavailable:
            unavailable
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
            notAttempted
        case .registered:
            registered
        case .apnsRefused:
            apnsRefused
        case .unreachable:
            unreachable
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
            sessionExpired
        case 429:
            tooManyAttempts
        default:
            refused(status)
        }
    }
}
