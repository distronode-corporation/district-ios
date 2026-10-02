import DistrictModel
import Foundation

/// Every string on the Support screens.
///
/// ⛔ "SUPPORT" IS HELP **FROM DISTRONODE**, AND NOTHING HERE MAY BE WORDED SO THAT
/// IT COULD ALSO DESCRIBE THE DESK. The desk is the tenant's OWN queue: their
/// customers' tickets, answered by their agent. Both surfaces have requests,
/// threads, replies and a close, so the labels are the only thing keeping them
/// apart in a navigation list — which is why the web sidebar carries an explicit
/// instruction beside its two entries and why a bare "Tickets" or "Inbox" on
/// either one undoes the distinction. Every title and subtitle below names
/// Distronode or "our team" on purpose.
///
/// ⚠️ ITS OWN FILE FOR THE REASON `MarketplaceCopy` AND `DialerCopy` HAVE ONE:
/// `swiftlint --strict` reports the 500-line `file_length` warning as an error, and
/// a screen with a compose form, a thread and three writes carries more prose than
/// a view file can hold alongside its layout.
enum SupportCopy {
    // MARK: - The list

    static let title = "Support"

    /// ⛔ THE SUBTITLE IS WHERE THE DIRECTION IS STATED, because a one-word nav
    /// label cannot carry it. The web page says the same thing in its own header.
    static let subtitle = "Requests you have raised with the Distronode team."

    /// ⛔ THE ONLY RESPONSE-TIME CLAIM THIS PRODUCT MAKES, WORD FOR WORD. It is the
    /// same sentence the public `/support` pages, the reply emails and the web
    /// dashboard carry, and it is a commitment rather than a statistic: no
    /// percentile, no "average", no measured number. Anything more specific would
    /// need evidence we do not publish. Reuse this constant, never retype it.
    static let sla = "We reply within one business day."

    static let newRequest = "New request"

    static let emptyTitle = "No support requests yet"

    static let emptyBody = "Anything broken, unclear or missing, open a request and it goes straight to our team."

    /// ⛔ NOT THE EMPTY-QUEUE COPY. "No support requests yet" is a claim about the
    /// WORKSPACE; this is a statement about US. Showing the first when the second is
    /// true tells a customer with open tickets that they have none: they stop chasing
    /// and nobody here ever sees the request.
    static let listFailedTitle = "We could not load your support requests."

    static let listFailedBody = "Your requests are still open, this screen just could not read them."

    /// ⚠️ A viewer never reaches this screen at all (every route excludes them, the
    /// READS included), so there is no read-only variant of it. Recorded here
    /// because its absence looks like an oversight beside Marketplace and Billing,
    /// which both have one.
    static let unfiledStatus = "Being opened"

    // MARK: - Provenance chips

    /// ⚠️ SHOWN ONLY FOR `voice-call`. A request raised here or on the public form is
    /// exactly what the reader expects and a chip saying so is noise; a request an
    /// unresolved phone call filed under this workspace is one the customer has no
    /// memory of writing.
    static let fromPhoneCall = "From a phone call"

    /// ⚠️ SHOWN ONLY WHEN THE REGION IS NOT THE DEFAULT `us`, for the same reason:
    /// it answers "why does this one look different", which only a non-default
    /// region raises.
    static let defaultRegion = "us"

    // MARK: - Composing one

    static let composeTitle = "New support request"
    static let composeKind = "What is it about"
    static let composeSubject = "Subject"
    static let composeMessage = "What is happening"

    /// ⚠️ RENDERED AS A HINT UNDER THE FIELD RATHER THAN AS A PLACEHOLDER.
    /// ``SettingsField`` uses its own label as the placeholder, so guidance this long
    /// has nowhere else to go, and it is the one line that materially improves what
    /// arrives in a human's queue.
    static let composeMessageHint = "What you expected, what happened instead, and when it started."

    static let composeSend = "Send to Distronode"
    static let composeSending = "Sending…"
    static let composeCancel = "Cancel"

    /// ⚠️ The route requires both, so this is checked before a round trip rather
    /// than after one. Subject is `min(3)` server-side.
    static let composeIncomplete = "A subject and a description are both needed."

    /// ⛔ THE LABELS ARE NOT THE WIRE VALUES. `SupportRequestKind`'s raw values are
    /// the vocabulary the route validates; these are what a person reads. Same rule
    /// the contact inquiry types follow.
    static func kindLabel(_ kind: SupportRequestKind) -> String {
        switch kind {
        case .problem: "Something is broken"
        case .question: "A question"
        case .suggestion: "A suggestion"
        }
    }

    // MARK: - What happened to a new request

    /// ⚠️ THE ORDINARY SUCCESS.
    static let filed = "Your request is open. We reply by email and here."

    /// ⛔ A SUCCESS, WORDED AS ONE. `deduplicated` means the idempotency key did its
    /// job and this submit collapsed onto the request already in the queue. Wording
    /// it as a fault is what invites a third attempt.
    static let deduplicated = "That request is already open. We reply by email and here."

    /// ⚠️ ALSO A SUCCESS: the claim row exists and the recovery sweep will file it,
    /// so the honest sentence is that we have it.
    static let pending = "We have your request. It is being opened now and will appear here shortly."

    // MARK: - The thread

    /// ⚠️ NO "ALL REQUESTS" BACK LABEL. The web needs one because its list and its
    /// thread are one component switched by state; here the thread is a real
    /// destination and `NavigationStack` draws the back affordance itself.
    static let threadLoading = "Loading the conversation…"

    /// ⚠️ FORMATTED THROUGH ``WireDate/display(_:in:)``, WHICH FALLS BACK TO THE
    /// RAW ISO STRING. The models carry the instant as a `String` rather than through
    /// a decoder strategy, which would have to be right for every timestamp on the
    /// surface, so the formatting is the App target's and the fallback keeps an
    /// unparseable instant visible rather than blanking the line.
    static func opened(_ readableDate: String) -> String {
        "Opened \(readableDate)"
    }

    static let replyLabel = "Your reply"
    static let replyPlaceholder = "Add to this request…"

    /// ⚠️ A DIFFERENT PLACEHOLDER ON A RESOLVED REQUEST, because replying is still
    /// the supported path and is the ONLY path: there is no reopen, here or on the
    /// server, so the invitation has to be explicit.
    static let replyPlaceholderResolved = "This request is resolved. Reply if it is not."

    static let replySend = "Send reply"
    static let replySending = "Sending…"

    /// ⛔ SHOWN WHEN A REQUEST HAS NO ATLASSIAN THREAD YET. The reply route answers
    /// 409 for this, and accepting the text would silently drop the one message the
    /// customer wanted us to see.
    static let notFiledYet = "This request is still being opened. You will be able to reply in a moment."

    static let threadFailed = "We could not open that request."

    static let close = "Mark resolved"
    static let closing = "Closing…"

    /// ⚠️ THE SERVER'S OWN `statusName` IS INTERPOLATED because the live desk
    /// workflow is localised and printing "Closed" would put English over a status
    /// Atlassian spells otherwise.
    static func closed(_ statusName: String) -> String {
        "This request is now \(statusName). Reply if it is not resolved."
    }

    /// ⚠️ A FRESHLY FILED REQUEST HAS NO COMMENTS: the description the customer
    /// typed is the ticket's own body rather than a message, so the commonest thread
    /// a new customer opens is empty and must not read as a failure.
    static let threadEmpty = "No replies yet. We reply within one business day."

    // MARK: - Failed writes

    static let dismiss = "Dismiss"

    /// ⛔ SHOWN UNDER A FAILURE WHOSE WRITE MAY HAVE LANDED, AND IT IS THE OTHER HALF
    /// OF WITHDRAWING THE BUTTON. A 5xx, a dropped connection and a contract
    /// mismatch all leave a reply or a close that may already be in the customer's
    /// own thread, so re-arming the control would post a second copy. Reopening the
    /// request is the honest way back, because it re-reads.
    static let writeUnrepeatable = "This will not be sent again from here. "
        + "The answer did not come back, so it may already have gone through. Reopen the request to check."
}
