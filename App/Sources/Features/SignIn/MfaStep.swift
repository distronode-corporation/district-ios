import DistrictNetwork
import Foundation

/// How one authenticator-code submission ended. Produced by
/// ``AppleSignInController/submitCode(_:for:now:)``.
enum MfaCodeOutcome: Equatable {
    case success
    /// The server's 401: wrong code, spent code, or a locked account. The ticket stands.
    case wrongCode
    /// The ticket is gone (expired, spent, or refused): start again from the Apple button.
    case expired
    case rateLimited
    case unreachable

    /// What the code step does next.
    ///
    /// ⛔ ONLY `expired` CLOSES THE SHEET WITHOUT SIGNING IN. Every other refusal leaves
    /// the ticket usable, so the person stays on the sheet and types again; closing it
    /// there would throw away a ticket over a typo and cost a second Apple prompt.
    /// `unreachable` stays open too: the person decides whether to send again.
    var reaction: MfaStepReaction {
        switch self {
        case .success:
            .signedIn
        case .wrongCode:
            .stayOpen(MfaCopy.wrongCode)
        case .expired:
            .startOver(MfaCopy.expired)
        case .rateLimited:
            .stayOpen(SessionCopy.tooManyAttempts)
        case .unreachable:
            .stayOpen(SessionCopy.unreachable)
        }
    }
}

/// What ``SessionModel`` does with an ``MfaCodeOutcome``.
enum MfaStepReaction: Equatable {
    /// The grant was adopted: close the sheet and settle the session.
    case signedIn
    /// Keep the sheet and show this sentence under the field.
    case stayOpen(String)
    /// Close the sheet; the sign-in screen shows this sentence.
    case startOver(String)
}

/// The code step in progress, as the sheet's item.
///
/// ⚠️ ITS OWN IDENTITY, NOT THE TICKET'S. `sheet(item:)` needs `Identifiable`, and an id
/// derived from the ticket would put a credential into SwiftUI's view identity, where
/// debugging tools print it.
struct PendingMfa: Identifiable, Equatable {
    let id = UUID()
    let challenge: NativeMfaChallenge
}
