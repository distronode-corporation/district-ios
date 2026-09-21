import DistrictData
import DistrictModel
import Foundation

/// What the composer is allowed to send, on which channel, and under what subject.
///
/// ⛔ THE CHANNEL IS CHOSEN HERE. ``ConversationSummary/replyTargets`` knows every
/// channel a thread can be answered on, the route carries that whole
/// `[ReplyTarget]` set, ``ThreadTarget`` holds it plus a selected index, and
/// ``selectReplyTarget(_:)`` below is the switch.
///
/// ⛔ BUT THIS FILE DOES NOT DECIDE WHAT IS SENDABLE. Sendability is server-decided
/// and the ORDER is ``ConversationSummary/replyTargets``', so this file may narrow a
/// choice among already-permitted channels and may never add one. Deriving a
/// channel from the shape of an address is the thing ``ReplyTarget`` exists to
/// prevent.
///
/// ⛔ AND THE DEFAULT IT NAMES IS HONEST, which is the half that matters most:
/// `replyTargets` does not put SMS first on a thread the customer has only ever
/// emailed. Otherwise an email thread whose contact has a number on file would be
/// answered by billable SMS with nothing on screen saying so.
extension ThreadModel {
    // MARK: - Choosing the channel

    /// Every channel this thread can be answered on, best first, for the picker.
    ///
    /// ⚠️ THE PICKER DRAWS ONLY WHEN THERE ARE TWO OR MORE. One target is a fact
    /// rather than a choice, and a control offering a single option invites the
    /// operator to look for the other one.
    var replyTargets: [ReplyTarget] {
        target.replyTargets
    }

    /// Which of ``replyTargets`` the next send will use.
    var selectedReplyIndex: Int {
        target.selectedIndex
    }

    /// Point the composer at another of this thread's channels.
    ///
    /// ⛔ THE TYPED TEXT SURVIVES, AND THAT IS THE WHOLE POINT OF A SWITCH RATHER THAN
    /// A NEW SCREEN. The operator has written a reply to a person; which wire it
    /// leaves on is a separate decision and changing it must not cost them the words.
    /// ``composerText`` is deliberately untouched here, and so is the autosave timer —
    /// no debounce is armed, because nothing the operator typed has changed and a
    /// write would spend one of the workspace's 60/min to store identical bytes.
    ///
    /// ⛔ THE THREAD KEY DOES NOT MOVE EITHER: THERE IS ONE DRAFT PER THREAD, NOT ONE
    /// PER CHANNEL. The drafts row is keyed on `(workspaceId, threadKey, authorEmail)`
    /// and the server has no channel column, so a per-channel draft is not
    /// representable — and it is not wanted: the half-finished reply is about the
    /// customer, not about SMS. See the ⛔ on ``ThreadTarget/threadKey``.
    ///
    /// ⛔ MOVING TO EMAIL DISCARDS STAGED IMAGES **AND SAYS SO**. The email branch of
    /// `messages/send` never looks at `mediaUrls`, so leaving them staged would send a
    /// message the operator believes carries pictures and the customer receives
    /// without them — a loss nothing downstream reports, because the send succeeds.
    /// Dropping them silently is the worse half of a bad choice, so
    /// ``ThreadContent/channelNote`` carries the sentence and it survives until the
    /// next switch or send.
    /// ⚠️ THE UPLOADED ROWS ARE NOT DELETED SERVER-SIDE and there is no route that
    /// would; they become orphan `MessageMedia` rows, exactly as
    /// ``removeAttachment(_:)`` documents.
    ///
    /// ⚠️ EVERYTHING ELSE IS DERIVED AND THEREFORE NEEDS NO RECOMPUTE. ``canAttach``,
    /// ``canReply``, ``requiresSubject`` and ``channelName`` all read
    /// ``ThreadTarget/replyTarget``, which is why they are computed properties: a
    /// stored copy is a second answer that goes stale here.
    ///
    /// ⚠️ AND THE SUBJECT IS SEEDED AFTER, NOT CLEARED. Switching SMS → email needs a
    /// subject the operator has not typed, and ``seedSubjectIfNeeded()`` fills an
    /// EMPTY box with `Re: <the thread's newest subject>` and invents nothing. A
    /// subject already typed is theirs and stays; switching email → SMS leaves it in
    /// place too, because ``outgoingSubject`` drops it on a channel that takes none
    /// and a switch back should not have cost them the line.
    func selectReplyTarget(_ index: Int) {
        guard index != target.selectedIndex else { return }
        let wasAttachable = canAttach
        target.select(index)
        guard index == target.selectedIndex else { return }
        dropAttachmentsIfChannelCannotCarryThem(wasAttachable: wasAttachable)
        seedSubjectIfNeeded()
    }

    /// The attachment half of a channel switch.
    ///
    /// ⚠️ SPLIT OUT SO ``selectReplyTarget(_:)`` READS AS A LIST OF DECISIONS rather
    /// than as one function doing five things, and because the note it writes needs a
    /// sentence of its own.
    ///
    /// ⛔ IT ONLY FIRES ON THE SMS → EMAIL DIRECTION. Going the other way there is
    /// nothing staged to lose (the Attach control was hidden), so a note there would
    /// be an alarm about nothing.
    private func dropAttachmentsIfChannelCannotCarryThem(wasAttachable: Bool) {
        guard var content = current else { return }
        content.channelNote = nil
        guard wasAttachable, !canAttach, !content.attachments.isEmpty else {
            setContent(content)
            return
        }
        let count = content.attachments.count
        content.attachments = []
        content.channelNote = Self.attachmentsDropped(count: count)
        setContent(content)
    }

    /// ⚠️ SINGULAR AND PLURAL SPELLED OUT, matching the thread's own attachment
    /// badge. "1 images" is the kind of detail that makes a product look unfinished.
    ///
    /// ⚠️ IT NAMES THE CHANNEL AS THE REASON rather than saying "not supported". The
    /// operator's next action is either to switch back or to send without them, and
    /// only the first sentence tells them which is available.
    private static func attachmentsDropped(count: Int) -> String {
        let noun = count == 1 ? "image was" : "\(count) images were"
        return "\(noun) removed: email replies cannot carry attachments. Switch back to SMS to send them."
    }

    // MARK: - The channel, said out loud

    /// The outgoing channel's name, or nil when this thread has nothing to reply on.
    ///
    /// ⚠️ NOT DERIVED FROM THE SHAPE OF THE ADDRESS. The pair was chosen by
    /// ``ConversationSummary/replyTargets`` and carried here verbatim; reading an `@`
    /// out of the recipient would be a second, disagreeing decision — the exact thing
    /// ``ReplyTarget`` exists to prevent.
    ///
    /// ⚠️ THE NAMING ITSELF LIVES IN ``ThreadChannelName``, and that is the point
    /// rather than tidiness: the picker has to label a target
    /// that is NOT the selected one, so a naming rule reachable only through
    /// `target.replyTarget` could not serve it — and two copies of the rule is how the
    /// badge and the segment come to disagree about what "WhatsApp" is called.
    var channelName: String? {
        guard let channel = target.replyTarget?.channel else { return nil }
        return ThreadChannelName.of(channel)
    }

    /// Where the reply goes, for the line under the channel's name.
    var recipientName: String? {
        target.replyTarget?.to
    }

    // MARK: - The subject

    /// True when the outgoing channel is email, and therefore needs one.
    ///
    /// ⚠️ THE CHANNEL DECIDES, NOT THE THREAD'S HISTORY. A thread of SMS answered by
    /// email needs a subject; a thread of email answered by SMS must not send one,
    /// because `messages/send`'s SMS branch has no use for it and the drafts row
    /// stores null on an SMS thread.
    var requiresSubject: Bool {
        target.replyTarget?.channel == MessageChannel.email
    }

    /// The subject to put on the wire, or nil when the channel does not take one.
    ///
    /// ⛔ NEVER A BLANK STRING. `messages/send` reads
    /// `(typeof subject === "string" && subject.trim()) || "Message from District"`, so
    /// an empty subject and an absent one are the SAME thing to the server: both get
    /// the literal. Sending `""` would therefore look like a fix and be none.
    var outgoingSubject: String? {
        guard requiresSubject, !Self.isBlank(composerSubject) else { return nil }
        return composerSubject
    }

    /// Whether Send may be offered at all.
    ///
    /// ⛔ AN EMAIL WITH NO SUBJECT IS REFUSED HERE RATHER THAN SENT AND SUBSTITUTED.
    /// The server does not fail that send: it titles it "Message from District" and
    /// delivers, so nothing tells the operator, and the customer's mail client threads
    /// the reply onto a conversation of its own. Refusing is the only place this can be
    /// caught, and it is why the box is a required field rather than a nicety.
    ///
    /// ⚠️ THE BODY RULE IS UNCHANGED: blank refuses even with images attached, because
    /// `messages/send` guards on `!body` before it looks at `mediaUrls`.
    var canSendNow: Bool {
        guard !Self.isBlank(composerText) else { return false }
        guard requiresSubject else { return true }
        return !Self.isBlank(composerSubject)
    }

    /// Fill an empty subject with `Re: <the thread's newest subject>`.
    ///
    /// ⛔ ONLY WHEN THE BOX IS EMPTY, so it can add and never overwrite — the same rule
    /// ``restoreDraft()`` applies to the body, and for the same reason: adopting into
    /// an empty box can only help, replacing a non-empty one can only lose.
    ///
    /// ⛔ AND IT INVENTS NOTHING. ``ReplySubject/reply(to:)`` returns nil for a thread
    /// that has never carried an email subject, and this leaves the box empty for the
    /// operator to fill rather than manufacturing a topic nobody chose.
    ///
    /// ⚠️ IT IS NOT PERSISTED BY ITSELF. A derived line arms no autosave (see
    /// ``adoptSubject(_:)``), so a thread the operator opens and leaves alone writes
    /// nothing; the moment they type, the subject travels with the draft.
    func seedSubjectIfNeeded() {
        guard requiresSubject, composerSubject.isEmpty else { return }
        guard let derived = ReplySubject.reply(to: current?.events ?? []) else { return }
        adoptSubject(derived)
    }

    // MARK: - The autosave timer

    /// (Re)arm the debounced draft write.
    ///
    /// ⚠️ THE DEBOUNCE IS RESTARTED, NOT EXTENDED FROM THE FIRST EDIT. A sustained
    /// typist would otherwise never save at all.
    ///
    /// ⚠️ IT TAKES THE BODY BECAUSE ``persistDraft(_:)`` DOES. The subject and the
    /// attachments are read at fire time instead, so an edit to either during the
    /// window lands on the draft the timer is about to write.
    func armAutosave(_ text: String) {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDebounce)
            guard !Task.isCancelled else { return }
            await self?.persistDraft(text)
        }
    }
}

/// What one channel is called on screen.
///
/// ⛔ ONE VOCABULARY FOR THE BADGE AND THE PICKER, BECAUSE THE PICKER LABELS A TARGET
/// THAT IS NOT THE SELECTED ONE. ``ThreadModel/channelName`` reads through
/// `target.replyTarget`, so it can only ever name the CURRENT channel; a segmented
/// control has to name both. Two copies of this rule is how a badge saying "Email"
/// ends up beside a segment saying "EMAIL".
///
/// ⚠️ AN `if` CHAIN RATHER THAN A `switch`, BECAUSE ``MessageChannel`` IS A NAMESPACE
/// OF `String` CONSTANTS AND NOT AN ENUM WITH CASES. A `switch` over those matches
/// through `~=` and needs a `default` anyway, so the chain says the same thing with
/// one less way to be surprised.
enum ThreadChannelName {
    /// ⚠️ A CHANNEL THIS CLIENT DOES NOT KNOW IS STILL NAMED, uppercased, rather than
    /// hidden. The server can add one; showing the raw word is worse copy and better
    /// information than silently drawing a control that says nothing.
    static func of(_ channel: String) -> String {
        if channel == MessageChannel.sms {
            return "SMS"
        }
        if channel == MessageChannel.email {
            return "Email"
        }
        if channel == MessageChannel.whatsapp {
            return "WhatsApp"
        }
        return channel.uppercased()
    }
}
