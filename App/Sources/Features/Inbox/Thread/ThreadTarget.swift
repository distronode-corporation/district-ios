import DistrictData
import DistrictModel
import Foundation

/// Which conversation this is, as one value.
///
/// ⛔ FOUR FIELDS THAT MUST AGREE, SO THEY TRAVEL TOGETHER. ``threadKey`` is the
/// drafts table's key, ``selector`` is the timeline's, and ``replyTarget`` is where a
/// send goes — three vocabularies for one thread, and assembling them from
/// independent navigation arguments is how a draft gets saved against one thread and
/// displayed in another. The same reasoning that put `to` and `channel` inside
/// ``ReplyTarget``.
///
/// ⚠️ IT IS BUILT ONCE, IN ``ThreadModel/init(container:workspaceId:role:threadKey:replyTargets:)``,
/// from the route's own associated values. `Route.thread` carries the ordered SET of
/// reply targets because a `Route` has to be `Hashable` and has to survive a process
/// death; this is where the current CHOICE among them lives.
struct ThreadTarget {
    let workspaceId: String
    /// `contact:<id>` or `addr:<normalized>`.
    ///
    /// ⛔ THE DRAFTS ROUTE VALIDATES THIS PREFIX AND 400s ANYTHING ELSE, which is
    /// deliberate: a key outside those two forms names a thread the Inbox can never
    /// show, so storing a draft under it would create a row nothing could restore.
    ///
    /// ⛔ AND IT DOES NOT MOVE WHEN THE CHANNEL DOES. There is ONE DRAFT PER THREAD,
    /// not one per channel: the drafts row is keyed on `(workspaceId, threadKey,
    /// authorEmail)` and the server has no channel column at all, so switching from
    /// SMS to email keeps writing and restoring the same row. That is also the
    /// behaviour an operator expects — the half-typed reply is about the customer,
    /// not about the wire it leaves on.
    let threadKey: String
    /// ⛔ Nil when ``threadKey`` is in neither form, which is a malformed destination
    /// rather than an empty thread. See ``selector(threadKey:)``.
    let selector: ThreadSelector?

    /// Every channel this thread can be answered on, best first.
    ///
    /// ⛔ CHOSEN UPSTREAM AND ONLY CARRIED HERE.
    /// ``ConversationSummary/replyTargets`` gates each entry on the SERVER-DECIDED
    /// `canSms`/`canEmail` and picks the address; this type must never add one,
    /// remove one, or reorder the list. Reordering would answer an email-only thread
    /// with billable SMS, which is the defect that ordering prevents.
    ///
    /// ⛔ EMPTY MEANS NO REPLY BOX AT ALL, never "reply on SMS".
    let replyTargets: [ReplyTarget]

    /// Which of ``replyTargets`` the composer is currently pointed at.
    ///
    /// ⚠️ AN INDEX RATHER THAN A COPY OF THE TARGET, so "which one is selected" and
    /// "what the choices are" cannot disagree. A stored `ReplyTarget` would let a
    /// selection name a pair that is not in the list.
    ///
    /// ⚠️ IT IS NOT VALIDATED ON WRITE AND ``replyTarget`` IS TOTAL INSTEAD. Guarding
    /// the setter would mean two places that know the bounds; reading through one
    /// bounds-checked accessor means an out-of-range value degrades to "nothing to
    /// reply on", which is the same answer an empty list gives and is already handled
    /// everywhere.
    private(set) var selectedIndex: Int

    /// The pair the next send will use.
    ///
    /// ⛔ Nil when there is nothing to reply on. The caller must then offer no reply
    /// box at all rather than one that 4xxs on send.
    var replyTarget: ReplyTarget? {
        guard replyTargets.indices.contains(selectedIndex) else { return nil }
        return replyTargets[selectedIndex]
    }

    init(workspaceId: String, threadKey: String, replyTargets: [ReplyTarget]) {
        self.workspaceId = workspaceId
        self.threadKey = threadKey
        selector = Self.selector(threadKey: threadKey)
        self.replyTargets = replyTargets
        // ⚠️ THE SERVER'S OWN FIRST CHOICE, WHICH IS THE POINT OF THE LIST BEING
        // ORDERED. `replyTargets` puts the thread's own traffic first, so an
        // email-only conversation opens on email rather than on billable SMS.
        selectedIndex = 0
    }

    /// Point the composer at another channel.
    ///
    /// ⚠️ IT ONLY MOVES THE INDEX. Everything that follows from the choice —
    /// attachments, the subject requirement, the note about dropped images — belongs
    /// to ``ThreadModel/selectReplyTarget(_:)``, because those touch loaded content
    /// and this type holds none.
    ///
    /// ⚠️ AN OUT-OF-RANGE INDEX IS IGNORED RATHER THAN CLAMPED. Clamping would answer
    /// a caller's mistake by silently sending on a channel it did not name, and on
    /// this surface the two channels differ in whether the message costs a carrier
    /// segment.
    mutating func select(_ index: Int) {
        guard replyTargets.indices.contains(index) else { return }
        selectedIndex = index
    }

    /// Which thread to read, from the route's opaque key.
    ///
    /// ⛔ THE PREFIX IS STRIPPED, AND SENDING THE WHOLE KEY WOULD MATCH NOTHING. The
    /// timeline route's address parameter takes a counterpart, so `addr:14165550123`
    /// entire is not a value it can ever match — the suffix is. That suffix is the
    /// server's own normalised address key (bare digits for a phone, lowercased for
    /// an email) and the route re-normalises whatever it is handed, so giving it back
    /// is idempotent rather than lossy.
    ///
    /// ⛔ AND A KEY IN NEITHER FORM PRODUCES NO SELECTOR. The drafts route 400s
    /// anything outside those two prefixes, so a third form names a thread nothing
    /// could show; guessing an address out of it would read some other conversation.
    ///
    /// ⚠️ PREFERS THE CONTACT ID, matching ``ThreadSelector/forConversation(_:)``: it
    /// is exact, it survives an address changing, and it is the only thing that
    /// matches a message row whose counterpart was never normalizable.
    static func selector(threadKey: String) -> ThreadSelector? {
        if threadKey.hasPrefix(contactKeyPrefix) {
            let id = String(threadKey.dropFirst(contactKeyPrefix.count))
            return id.isEmpty ? nil : .contact(id)
        }
        if threadKey.hasPrefix(addressKeyPrefix) {
            let address = String(threadKey.dropFirst(addressKeyPrefix.count))
            return address.isEmpty ? nil : .address(address)
        }
        return nil
    }

    /// ⛔ NO PAIR REASSEMBLER HERE: THE TYPE ENFORCES "BOTH HALVES OR NEITHER". An
    /// email address on the `sms` channel reaches the carrier branch, which does no
    /// address-shape validation at all, so a half pair must never exist. The route
    /// carries `[ReplyTarget]`, which makes a half pair unrepresentable in transit
    /// rather than refused by a guard. ⚠️ And it binds every caller: the pair is CHOSEN
    /// by ``ConversationSummary/replyTargets`` and only carried here, and nothing may
    /// derive a channel from the shape of an address.
    private static let contactKeyPrefix = "contact:"
    private static let addressKeyPrefix = "addr:"
}

/// Everything one loaded thread is showing, in one value.
///
/// ⛔ A STRUCT RATHER THAN NINE ASSOCIATED VALUES ON THE ENUM CASE. Every write in
/// the model changes ONE field and leaves the rest alone (Android spells that
/// `copy(sending = true)`), and destructuring nine bindings at each of those sites is
/// how a send failure ends up clearing the attachments it was supposed to keep.
///
/// ⚠️ ``attachments`` HOLDS URLs, NOT ``UploadedMedia``, AND THAT IS FORCED RATHER
/// THAN CHOSEN. A restored draft carries a list of strings and nothing else, and
/// `UploadedMedia` publishes no initialiser, so this target cannot build one to stand
/// in. The URL is also the only field the send and the draft upsert actually take.
struct ThreadContent {
    /// ⚠️ OLDEST FIRST, the order both server versions send and the order a
    /// transcript is read in.
    var events: [ThreadEvent]
    /// The server's `pageInfo.hasMore` for the OLDEST page held so far.
    var hasMore: Bool
    /// ⛔ Nil means there is no anchor to page from, so the control must not act even
    /// when ``hasMore`` is true. See ``ThreadCursor``.
    var cursor: ThreadCursor?
    var loadingOlder: Bool
    /// ⛔ A failed older read, shown at the TOP where the tap happened. It never
    /// replaces the thread.
    var olderFailure: FailureText?
    /// ⛔ A failed DRAFT read, which is a different fact from "this thread has no
    /// draft" and must never be drawn as one. Shown in the composer, where the
    /// consequence is: the box may not be showing a reply that is already saved, and
    /// the next autosave overwrites it. See ``ThreadModel/restoreDraft()``.
    var draftFailure: FailureText?
    /// Rows the reader could not read, accumulated across pages. Non-zero is contract
    /// drift worth a bug report, not a user error.
    var incompleteCount: Int
    var sending: Bool
    /// ⚠️ ONE SLOT FOR SEND, ATTACH AND GENERATE. All three fail in the same place on
    /// screen, and three slots would mean three dismiss controls in one location.
    var sendFailure: FailureText?
    /// ⛔ Already uploaded, capped at ``ThreadModel/maximumAttachments``.
    var attachments: [String]
    /// What changed when the operator switched channel, said out loud.
    ///
    /// ⛔ ITS OWN SLOT RATHER THAN A FOURTH TENANT OF ``sendFailure``, AND THE REASON
    /// IS THE ONE FACT IT HAS TO CARRY: moving a reply from SMS to email DISCARDS the
    /// staged images, because the email branch of `messages/send` never looks at
    /// `mediaUrls`. `sendFailure` is cleared by the next send, attach or generate and
    /// by its own Dismiss, so this sentence would disappear at exactly the moment it
    /// matters — while the operator is composing the message they believe still has
    /// pictures on it. It follows ``draftFailure``'s shape: a named field for a named
    /// event, drawn beside the control it belongs to.
    ///
    /// ⛔ AND SILENTLY DROPPING THEM IS THE ALTERNATIVE THIS EXISTS TO REFUSE. An
    /// attachment that vanished without a word is a message the operator sends
    /// believing it carries something it does not, and nothing downstream would tell
    /// them: the email arrives, looking fine, missing the photo the customer asked for.
    ///
    /// ⚠️ INFORMATIONAL, NOT A FAILURE. Nothing went wrong and there is nothing to
    /// retry, so it is drawn in muted rather than destructive ink and cleared by the
    /// next channel change or send.
    var channelNote: String?
    var attaching: Bool
    var draftGenerating: Bool
}

extension ThreadContent {
    /// The state a freshly read page starts in.
    static func from(_ page: ThreadPage) -> ThreadContent {
        ThreadContent(
            events: page.events,
            hasMore: page.hasMore,
            cursor: page.cursor,
            loadingOlder: false,
            olderFailure: nil,
            draftFailure: nil,
            incompleteCount: page.droppedEventCount,
            sending: false,
            sendFailure: nil,
            attachments: [],
            channelNote: nil,
            attaching: false,
            draftGenerating: false
        )
    }
}

/// What the thread screen is showing.
///
/// ⛔ `empty` CARRIES THE CONTENT, WHICH IS NOT THE USUAL SHAPE AND IS DELIBERATE.
/// Everywhere else in this app an empty state is a dead end; here the operator can
/// still REPLY, so the composer, its attachments and its in-flight flags have to
/// survive the case that says there is no history. It is reachable only after a
/// SUCCESSFUL read, which is the property that keeps "there is nothing" separate from
/// "we could not look" — see the ⛔ on ``FailureText``.
enum ThreadState {
    case loading
    case content(ThreadContent)
    case empty(ThreadContent)
    case failed(FailureText)
}
