import Foundation

/// Every string District Desk shows.
///
/// ⛔ THE FIRST JOB OF THIS FILE IS TO KEEP TWO SURFACES APART, AND IT IS NOT
/// DECORATION. District Desk is the tenant's OWN customers' tickets; Support is the
/// tenant raising something with DISTRONODE. They sit next to each other in the web
/// console's sidebar, where the labels are deliberately kept apart, and a bare
/// "Tickets" or "Inbox" on either one undoes that in a single word. Every title
/// and every empty state below says WHOSE customers it means, and none of them may be
/// shortened to a noun that could describe the other surface.
///
/// ⛔ AND NOTHING HERE MAY SAY "SUPPORT". The word belongs to the other queue. When
/// this screen has to point at Distronode, it names Distronode.
///
/// ⚠️ ONE FILE RATHER THAN LITERALS IN THE VIEWS, for the reason the settings copy
/// gives: a sentence that explains a consequence has to be readable beside the other
/// sentences that explain consequences, or the three of them drift into contradicting
/// each other about what turning the desk on actually does.
enum DeskCopy {
    // MARK: - The queue

    static let title = "Desk"

    /// ⛔ THE DISAMBIGUATION, and it is the point of the line rather than a subtitle: this
    /// queue is the TENANT'S customers, not the tenant's own tickets with us.
    ///
    /// ⚠️ THE SECOND SENTENCE DENIES RATHER THAN DIRECTS. Pointing at the website would
    /// turn a disambiguation into a signpost, and a signpost is what Guideline 3.1.1
    /// forbids: the distinction it exists to draw survives, the destination does not.
    static let subtitle = "Your customers' tickets, filed by your agent when a call "
        + "cannot be resolved. This is not where you raise something with Distronode."

    static let allFilter = "All"

    static let loadingQueue = "Loading your tickets…"

    static let emptyTitle = "No tickets yet"

    /// ⛔ SAYS WHAT WILL PUT SOMETHING HERE. An empty queue with no explanation reads
    /// as a broken screen on a surface most operators will meet before their first
    /// ticket exists.
    static let emptyMessage = "When a call your agent cannot resolve ends, it files the "
        + "ticket here with the call's own summary. You can also open one yourself."

    static let noMatchTitle = "No tickets match this filter"

    static let noMatchMessage = "Choose All to see the whole queue."

    // MARK: - The three states of the desk itself

    /// ⛔ OFF IS NOT EMPTY, AND THIS IS THE SENTENCE THAT KEEPS THEM APART. An empty
    /// queue here would be a lie: it reads as "no customer has ever contacted you"
    /// when the truth is that nothing is being recorded at all.
    static let offTitle = "District Desk is off"

    static let offMessage = "Turn it on and calls your agent cannot resolve are filed here "
        + "as tickets, and callers can ask it for the status of their own requests. "
        + "Nothing is recorded until you do."

    static let offAction = "Desk settings"

    /// ⛔ THE THIRD STATE, AND THE ONE MOST EASILY COLLAPSED INTO ONE OF THE OTHER TWO.
    /// A settings read that FAILED is not a desk that is off. Telling an operator it is
    /// off sends them to switch on something that may already be on; showing them an
    /// empty queue tells them nobody has ever written in. Say which one it is.
    static let unknownTitle = "We could not check your desk"

    static let unknownMessage = "This is not the same as your desk being switched off, "
        + "and it is not an empty queue. Nothing has changed; try again."

    // MARK: - One ticket

    static let threadFallbackTitle = "Ticket"

    static let loadingThread = "Loading the conversation…"

    static let noContactDetails = "No contact details recorded"

    static let fromCall = "From a phone call"

    static let setStatus = "Set status"

    static let replyPlaceholder = "Reply to your customer…"

    static let sendReply = "Send reply"

    static let emptyThread = "Nothing on this ticket yet."

    /// ⛔ THE CONFIRMED-APPEND RULE'S OWN SENTENCE. The reply is safe and unduplicated
    /// and this response could not show it, so the honest thing is to say the message
    /// is not on screen rather than to leave the thread looking as though nothing was
    /// sent — and rather than to draw the draft, which would claim a customer had been
    /// answered when the row may never have been written.
    static let replySentNotShown = "Your reply was sent. It is not shown here yet; "
        + "reload the ticket to see it."

    // ⛔ NO `replyFailed` / `statusFailed` HERE, AND THAT IS DELIBERATE. Such a string could
    // only sit on the right of `FailureText.from(error).message ?? …`, whose left side is a
    // non-optional `String`, so the fallback would be unreachable and the compiler says so.
    // ``FailureText`` is the ONE mapping every screen shares, and its own ⛔ says that is
    // what stops the next screen re-deriving it and getting it wrong — a per-feature
    // failure string is exactly that re-derivation. ``DeskModel`` uses it directly
    // (`notice = FailureText.from(error).message`, no fallback).

    // MARK: - Author labels

    /// ⛔ THE SERVER SENDS NO AUTHOR LABEL AND THE SHARED THREAD RENDERER'S FALLBACK
    /// NAMES DISTRONODE, which is the wrong company on a tenant's own desk. All three
    /// are supplied here for that reason rather than left to a default.
    static let authorCustomerFallback = "Your customer"

    static let authorTeam = "Your team"

    /// ⚠️ NAMES THE AGENT AS THE TENANT'S, not as ours. It is their agent, answering
    /// their calls, and the summary in the thread is its own note.
    static let authorAssistant = "District · your agent"

    /// ⚠️ AN AUTHOR KIND THIS BUILD HAS NOT LEARNED SITS ON THE TEAM'S SIDE and is
    /// labelled honestly rather than guessed at. Attributing it to the customer would
    /// be the damaging direction: it would put words in their mouth.
    static let authorUnknown = "Someone on your team"

    // MARK: - Creating a ticket

    static let composeTitle = "New ticket"

    static let composeSubtitle = "For something a customer raised another way: a walk-in, "
        + "an email, a note."

    static let subjectLabel = "Subject"

    static let messageLabel = "What they need"

    static let requesterNameLabel = "Customer name"

    static let requesterEmailLabel = "Email"

    static let requesterPhoneLabel = "Phone"

    static let createAction = "Open ticket"

    static let cancel = "Cancel"

    /// ⛔ THE ROUTE'S OWN RULE, checked locally so an operator is not charged a round
    /// trip to be told: subject and description are both required.
    static let createIncomplete = "A subject and a description are both needed."

    /// ⚠️ THE DEDUPLICATED CREATE, WHICH IS A SUCCESS. The key already produced a
    /// ticket, which is what the key is for; calling it an error would make a retried
    /// submit look broken and invite a third.
    static let createDeduplicated = "That ticket was already opened."

    static let createSucceeded = "Ticket opened."

    // MARK: - Settings

    static let settingsTitle = "Desk settings"

    static let settingsEyebrow = "District Desk"

    /// ⛔ THE DISAMBIGUATION AGAIN, because this card is reachable without passing the
    /// queue's own subtitle.
    static let settingsIntro = "A ticket queue for your own customers, with your agent as "
        + "its front line. Separate from raising a request with Distronode."

    static let enabledLabel = "Run a desk for my customers"

    /// ⛔ SAYS WHAT FLIPPING THIS DOES, BEFORE IT IS FLIPPED. Both consequences land on
    /// a LIVE CALL, so discovering them afterwards means discovering them in
    /// production. Opt-in is the whole safety story for this feature.
    static let enabledHelp = "Calls your agent cannot resolve are filed here as tickets "
        + "instead of reaching Distronode, and callers can ask it for the status of their "
        + "own requests: status only, never the contents of a thread."

    static let notifyLabel = "Email customers when your team replies"

    /// ⚠️ EVERY CLAUSE IS LITERALLY WHAT THE EMAIL SAYS and has to stay that way. The
    /// link is the customer's only entrance to the thread, and replies to the email
    /// itself genuinely go nowhere until intake ships.
    static let notifyHelp = "Best effort, and only when we hold an email address for them. "
        + "It carries a private link where they can read the whole request and reply. "
        + "Replies to the email itself are not tracked."

    static let brandNameLabel = "The name your customers see"

    /// ⛔ SAYS WHERE THE VALUE IS RENDERED, not just what it is. It is the heading on a
    /// page a stranger opens and the signature on every team reply there, so an
    /// internal shorthand would go out to people who are not our customers.
    static let brandNameHelp = "Shown at the top of the thread page your customers open "
        + "from their email, and used to sign your team's replies. Leave it blank to use "
        + "your workspace name."

    static let logoLabel = "The logo your customers see"

    /// ⛔ SAYS WHERE IT IS PUBLISHED AND WHO SEES IT, BEFORE A FILE IS PICKED. The image
    /// is served from a Distronode-controlled domain to an audience that is not ours,
    /// so "who can see this" is the first thing a tenant has to know rather than a
    /// footnote.
    static let logoHelp = "Shown at the top of the thread page your customers open, in "
        + "place of the name above. PNG, JPEG or WebP, up to 512 KB. It is hosted publicly "
        + "so their browser can load it, and anyone with a thread link can see it."

    static let logoSet = "A logo is set."

    static let logoNone = "No logo set."

    static let uploadLogo = "Upload logo"

    static let replaceLogo = "Replace logo"

    static let removeLogo = "Remove logo"

    static let uploadingLogo = "Uploading…"

    /// ⚠️ "COULD NOT BE READ" IS NOT "REFUSED". Those call for different next actions
    /// and collapsing them leaves an operator re-picking the same file.
    static let logoUnreadable = "That image could not be read. Please pick another."

    /// ⛔ THE TAKEDOWN'S HONEST HALF-ANSWER. The image is off the customer's page and
    /// the stored file was not deleted, which matters when the reason for removing it
    /// was that it should not be public at all.
    static let logoClearedNotDeleted = "The logo is off your customers' page, but the "
        + "stored image file was not deleted. Try removing it again."

    static let settingsUnavailable = "We could not read your desk settings."

    static let viewerNote = "Desk is available to agency and client members."
}
