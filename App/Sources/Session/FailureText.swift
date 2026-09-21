import DistrictData
import DistrictModel
import Foundation

/// What to tell the user about a failed request, and what to offer them next.
///
/// ⛔ ONE MAPPING, SHARED BY EVERY SCREEN, ON PURPOSE. The rule it enforces is that a
/// failure is never rendered as an absence of data: "we could not look" and "there
/// is nothing" are different answers, and showing the second when the first is true
/// reads as account loss. That was learned the expensive way on the web, where an
/// unreachable region produced an empty workspace list and routed a paying customer
/// to a checkout page. Keeping the mapping in one place is what stops the next
/// screen re-deriving it and getting it wrong. Mirrors Android's `FailureText.kt`.
///
/// ⚠️ Each screen still decides its own STATE. A 404 means "this account has no
/// workspace" on the overview and "this workspace is gone" in the call log; the
/// wording and what may be OFFERED come from here.
struct FailureText {
    /// What the user may do about it.
    ///
    /// ⛔ `retry` IS A CLAIM, NOT A DEFAULT. Offering "try again" for a contract
    /// mismatch or a role refusal is worse than offering nothing: the identical
    /// failure comes back, and the user concludes the app is broken in a way they
    /// caused. Only failures that a second attempt could genuinely change get it.
    enum Action {
        case retry
        case signIn
        case none
    }

    let message: String
    let action: Action
}

extension FailureText {
    /// Map a normalised API failure to user-facing copy.
    static func from(_ error: ApiError) -> FailureText {
        switch error {
        case let .http(status, message):
            fromHTTP(status: status, serverMessage: message)
        case .transport:
            // ⚠️ The session is intact. Nothing here should imply otherwise.
            FailureText(message: "You appear to be offline. Check your connection and try again.", action: .retry)
        case .decoding:
            // ⛔ CONTRACT DRIFT, NOT CONNECTIVITY. "Check your connection" would be
            // both wrong and unactionable, because retrying can never fix a response
            // shape this build cannot parse. Point at the app, offer no retry.
            FailureText(message: "This version of the app could not read that response. Please update.", action: .none)
        }
    }

    /// Map the workspace list's own failure type.
    ///
    /// ⛔ ITS OWN ENTRY POINT BECAUSE `regionsDegraded` HAS NOWHERE TO GO IN
    /// ``ApiError``. The 503 carries WHICH regions were unreachable, and that array
    /// is the only thing that makes the sentence specific. Collapsing it into a
    /// generic HTTP failure would lose it, and rendering it as an empty list would
    /// tell a paying customer their account is gone.
    static func from(_ error: WorkspaceListError) -> FailureText {
        switch error {
        case let .regionsDegraded(_, regions):
            FailureText(message: degradedMessage(regions: regions), action: .retry)
        case let .api(apiError):
            from(apiError)
        }
    }

    /// ⛔ THE SERVER'S OWN MESSAGE IS SHOWN FOR A 4xx AND NEVER FOR A 5xx, AND THAT
    /// ASYMMETRY IS THE ONE LEAK THIS MAPPING EXISTS TO CLOSE. On a 4xx the server
    /// authors a sentence for the user ("Contact already exists") that is more
    /// specific than anything a status code could infer. On a 5xx the contacts
    /// routes return the RAW exception message, so a Postgres constraint name or a
    /// Prisma stack fragment would reach a customer's screen: internal schema
    /// detail, in an alarming register, with nothing they can act on.
    private static func fromHTTP(status: Int, serverMessage: String?) -> FailureText {
        if status == 401 {
            return FailureText(message: "Your session has ended. Please sign in again.", action: .signIn)
        }
        if status == 402 {
            // ⛔ NOT RETRYABLE, SO IT MUST NOT FALL THROUGH TO THE `.retry` DEFAULT AT
            // THE BOTTOM OF THIS FUNCTION. The server answers 402 for a workspace whose
            // subscription is in a blocked state, on `messages/send` and
            // `messages/draft` among others, and both are routes this app calls. A
            // second attempt returns the identical refusal: the remedy is a billing
            // change made somewhere else entirely, which this app deliberately cannot
            // offer at all (App Store Review Guideline 3.1.3(b) keeps subscription
            // management out of it, see ``BillingCopy``). Offering "try again" for it is
            // exactly what the ⛔ on ``FailureText/Action/retry`` forbids.
            //
            // ⚠️ A WRONG ANSWER HERE WOULD BE INVISIBLE RATHER THAN HARMLESS. The
            // composer's failure strip draws Dismiss and never `action`
            // (``ComposerBar/failureStrip``), and ``DialerModel`` branches the envelope's
            // `subscription_inactive` code before this mapping ever runs, so the next
            // screen to render `action` is the one that would inherit a wrong offer.
            // ⚠️ THE SENTENCE NAMES NO WEB DASHBOARD. App Store Review Guideline 3.1.1
            // covers STEERING toward an external purchase as well as the purchase
            // itself. Naming where to go and pay is the part
            // that steers; saying the subscription is inactive is not.
            let fallback = "This workspace's subscription is not active."
            return FailureText(message: serverMessage ?? fallback, action: .none)
        }
        if status == 410 {
            // ⛔ GONE, NOT FAILED, AND NEVER RETRYABLE. A 410 is the server saying this
            // capability has been retired at this address — the scheduling console is
            // the live case, answering
            // `{"error":"Scheduling for this workspace is managed on the web dashboard.",
            // "code":"scheduler_console_retired"}`. Retrying re-fetches the same refusal
            // for as long as the user is willing to press the button.
            //
            // ⚠️ THE SERVER'S OWN SENTENCE WINS. It is the only party that knows WHY a
            // thing is gone and where the capability went; a client-side fallback that
            // guessed would go stale the moment the server's answer changed.
            return FailureText(message: serverMessage ?? "That is no longer available.", action: .none)
        }
        if status == 403 {
            // ⚠️ NOT RETRYABLE. The role will not change because the user pressed a
            // button again. It can change server-side, but "try again" implies this
            // attempt was unlucky.
            let fallback = "You do not have permission to do that in this workspace."
            return FailureText(message: serverMessage ?? fallback, action: .none)
        }
        if status == 404 {
            return FailureText(message: serverMessage ?? "That is no longer available.", action: .none)
        }
        if status >= 500 {
            return FailureText(message: "Something went wrong on our side. Please try again.", action: .retry)
        }
        return FailureText(message: serverMessage ?? "That request could not be completed.", action: .retry)
    }

    /// ⚠️ NAMES THE REGIONS WHEN THE SERVER NAMED THEM. "One or more regions" is
    /// true and useless; "the eu region" is what lets an operator decide whether the
    /// number they are looking at is the whole picture.
    private static func degradedMessage(regions: [String]) -> String {
        let head = "Your account is unchanged, but we could not reach"
        guard !regions.isEmpty else { return "\(head) every region. Please try again." }
        let named = regions.map { $0.uppercased() }.joined(separator: ", ")
        return "\(head) \(named). Some workspaces are missing from this list."
    }
}
