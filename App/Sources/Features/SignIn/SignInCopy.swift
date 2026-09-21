import Foundation

/// Sentences the sign-in screen shows that are not one of ``SessionModel``'s
/// session-state reasons.
///
/// ⛔ ``noAccount`` IS THE SERVER'S OWN SENTENCE, WORD FOR WORD, KEPT HERE RATHER
/// THAN READ FROM THE RESPONSE. `POST /api/auth/native/apple` answers 403 with
/// `{"error":"no_account","message":<this sentence>}` for an Apple ID no account
/// uses, and the client keys on the status alone (see
/// `NativeAuthClient.exchangeAppleIdentityToken`), so a body it cannot parse
/// still gets the right words. The two copies must stay identical;
/// `SignInCopyTests` pins this one.
///
/// ⛔ IT OFFERS NO WAY TO MAKE AN ACCOUNT, AND THAT IS THE POINT OF IT. Under
/// Guideline 3.1.1, Sign in with Apple creating an account for an unknown Apple ID is
/// grounds for rejection. Accounts exist only by invitation from a
/// workspace administrator, so the sentence says exactly that and nothing on this
/// screen links anywhere else. `StoreCopyTests` fails on registration-inviting
/// wording anywhere under `Features` and `Navigation`.
enum SignInCopy {
    static let noAccount = "No District AI account uses this Apple ID. "
        + "Ask your organization's administrator to invite you, then sign in with the invited email."
}
