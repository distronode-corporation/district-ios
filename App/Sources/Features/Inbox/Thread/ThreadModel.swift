import DistrictData
import DistrictModel
import Foundation
import Observation

/// One conversation: its interleaved history, the reply composer, and the composer's
/// saved draft.
///
/// ⛔ THE THREAD IS ADDRESSED BY `contactId` OR BY AN ADDRESS, EXACTLY ONE, AND
/// ``ThreadSelector`` IS WHAT ENFORCES IT. A thread whose counterpart never resolved
/// to a Contact row has only an address, which is why the route accepts both and why
/// this cannot assume an id exists.
///
/// ⛔ THE COMPOSER'S TEXT LIVES HERE, NOT IN A `@State` ON THE VIEW. It is the iOS
/// analogue of Android's `SavedStateHandle`: autosave has to READ it on a timer and
/// the AI draft button has to WRITE it, and a `@State` in the view can do neither. A
/// pushed-and-popped screen would also lose it.
///
/// ⚠️ PROCESS DEATH IS COVERED SEPARATELY. On its own this would bring a killed app back
/// to whatever the last autosave persisted rather than to the last keystroke;
/// ``flushDraft()``, in `ThreadDraftFlush.swift`, writes the composer when the scene
/// stops being active, which is where iOS puts an app before it suspends and later
/// kills it. ⚠️ A FOREGROUND
/// crash still loses the last edit, and `SavedStateHandle` does not survive one either:
/// it is written at the same point in the Android lifecycle.
///
/// ⛔ AUTOSAVE IS A DEBOUNCE, NOT A KEYSTROKE WRITE. The drafts route allows 60
/// writes/min per WORKSPACE and the budget is shared across every operator in it, so
/// a write per character would trip it in under a second and the 429 would land on
/// whichever colleague typed last.
@MainActor
@Observable
final class ThreadModel {
    /// ⚠️ THE SERVER'S CEILING ON `messages/send`, mirrored so the sixth pick is
    /// refused here rather than 400-ing a message that already holds five.
    static let maximumAttachments = 5

    /// ⚠️ TWO SECONDS, CHOSEN AGAINST THE SERVER'S 60 WRITES/MIN PER WORKSPACE rather
    /// than against typing feel. Two seconds bounds one composer to 30/min at
    /// absolute worst, and far less in practice because the timer restarts on every
    /// keystroke.
    static let autosaveDebounce: Duration = .seconds(2)

    private(set) var state: ThreadState = .loading

    /// The composer's text.
    ///
    /// ⛔ WRITTEN THROUGH ``composerTextChanged(_:)`` FROM THE VIEW, never bound
    /// directly: that method is the only thing that arms an autosave, and the two
    /// writes that must NOT arm one (a restored draft, which would immediately save
    /// back what it just read, and the clear after a successful send) set this
    /// property instead.
    private(set) var composerText: String = ""

    /// The email subject line.
    ///
    /// ⛔ IT EXISTS BECAUSE THE SERVER SUBSTITUTES A LITERAL FOR AN ABSENT ONE: without
    /// it every email reply an operator writes goes out titled "Message from District"
    /// and threads with none of them. See ``ReplySubject``.
    ///
    /// ⚠️ WRITTEN THROUGH ``subjectChanged(_:)`` FROM THE VIEW, exactly like
    /// ``composerText``: that method is the only one that arms an autosave, and the
    /// two writes that must not arm one (the restored draft's, and the `Re:` seeded
    /// on open) go through ``adoptSubject(_:)``.
    private(set) var composerSubject: String = ""

    /// ⛔ FALSE ALSO WHEN THERE IS NOTHING TO REPLY TO. `messages/send` excludes
    /// `viewer` server-side, and a thread the server marked neither `canSms` nor
    /// `canEmail` has no reachable address — offering a box there would collect a
    /// message that could only ever fail to send.
    ///
    /// ⚠️ COMPUTED RATHER THAN A `let`, BECAUSE THE CHANNEL CAN CHANGE.
    /// ``selectReplyTarget(_:)`` moves the selected target, so anything derived from
    /// it has to be read rather than remembered or
    /// the two will disagree the first time somebody switches.
    var canReply: Bool {
        canMutate && target.replyTarget != nil
    }

    /// ⛔ SMS ONLY, AND THE GATE IS THE CHANNEL RATHER THAN THE ROLE. The email branch
    /// of `messages/send` never looks at `mediaUrls` at all, so an attachment on an
    /// email thread would upload, cost a database write, and silently not be
    /// delivered. ⚠️ A workspace whose gateway resolves to Sinch is refused
    /// server-side and that is not knowable here, so it still sees this control and
    /// learns the truth from the server's own refusal text.
    ///
    /// ⚠️ COMPUTED FOR THE REASON ``canReply`` IS. This is the value a channel switch
    /// most obviously has to move: the Attach control appears on SMS and must be gone
    /// on email, and a stored `let` would leave it drawn.
    var canAttach: Bool {
        canMutate && target.replyTarget?.channel == MessageChannel.sms
    }

    /// Whether this ROLE may write at all, settled once from the route.
    ///
    /// ⚠️ THE HALF THAT CANNOT CHANGE, SEPARATED FROM THE HALF THAT CAN. A role is
    /// fixed for the lifetime of this model (``InboxView`` rebuilds on a workspace
    /// change) while the channel is not, so keeping them apart is what lets
    /// ``canReply`` and ``canAttach`` be derived without re-deriving the role.
    /// ⚠️ `allowsMutation` rather than `role != .viewer`, so an UNPARSED role also
    /// reads as read-only: ``WorkspaceRole/fromWire(_:)`` fails closed.
    let canMutate: Bool

    /// ⚠️ NEITHER IS `private`, AND ONLY BECAUSE ``restoreDraft()`` LIVES IN
    /// `ThreadDraftRestore.swift`; see the ⛔ on that file. App is one module and
    /// nothing outside this feature reads them.
    ///
    /// ⚠️ ``target`` IS A `var` FOR THE CHANNEL PICKER, and it is internal
    /// rather than `private(set)` for the same file-scoping reason: the only writer is
    /// ``selectReplyTarget(_:)``, which lives in `ThreadComposerRules.swift`. ⛔ Its
    /// `workspaceId`, `threadKey`, `selector` and `replyTargets` are all `let` on the
    /// struct, so the only thing a write can move is which target is selected — the
    /// thread cannot be re-pointed at another conversation by mistake.
    let inbox: InboxRepository
    var target: ThreadTarget

    /// The pending debounced save. Cancelled and replaced on every edit.
    ///
    /// ⚠️ NOT `private`, AND ONLY BECAUSE ``flushDraft()`` LIVES IN A SIBLING FILE. It
    /// does because this one is at the 500-line `file_length` ceiling `swiftlint
    /// --strict` enforces; App is one module and nothing else reads this.
    var autosaveTask: Task<Void, Never>?

    /// ⚠️ SET BEFORE THE FIRST `await`, so a second call cannot restore over text
    /// typed since the first one started.
    ///
    /// ⛔ AND CLEARED AGAIN WHEN THE READ FAILED, WHICH IS THE EASY HALF TO MISS. It is
    /// an in-flight lock plus a "we have the answer" latch, and a failure is not an
    /// answer: latching on one would make the composer permanently unable to learn
    /// about a draft that exists. See ``restoreDraft()``.
    var draftRestored = false

    /// Set once ``recordRead()`` has fired, so a retry of ``open()`` spends no second write.
    var readRecorded = false

    init(
        container: AppContainer,
        workspaceId: String,
        role: WorkspaceRole?,
        threadKey: String,
        replyTargets: [ReplyTarget]
    ) {
        // ⚠️ THE CONTAINER'S ONE REPOSITORY, NEVER ONE CONSTRUCTED HERE. A second
        // `InboxRepository` would carry a second `ApiClient` and reach a second
        // `TokenRefreshCoordinator`; see the ⛔ on ``AppContainer``.
        inbox = container.inbox
        target = ThreadTarget(
            workspaceId: workspaceId,
            threadKey: threadKey,
            replyTargets: replyTargets
        )
        // ⚠️ ONLY THE ROLE IS SETTLED HERE. ``canReply`` and ``canAttach`` are
        // derived from `target`, because a channel switch has to move both and a
        // stored copy would keep the Attach control drawn on an email reply.
        canMutate = WorkspaceRole.allowsMutation(role)
    }

    // MARK: - Reads

    /// Read the NEWEST window of the thread.
    ///
    /// ⚠️ THIS DISCARDS ANY OLDER PAGES ALREADY EXPANDED, AND ANY ATTACHMENTS. It is
    /// the retry path and the post-send refresh; both exist to show the operator the
    /// server's current truth, and after a send the attachments have gone out with
    /// it. Re-walking the cursor to rebuild scrollback nobody asked for would spend N
    /// requests, and the expand control is still there.
    func load() async {
        guard let selector = target.selector else {
            state = .failed(Self.unopenable)
            return
        }
        state = .loading
        switch await inbox.timeline(workspaceId: target.workspaceId, selector: selector) {
        case let .success(page):
            setContent(.from(page))
        case let .failure(error):
            state = .failed(FailureText.from(error))
        }
    }

    /// Expand the thread backwards by one page.
    ///
    /// ⛔ MERGED WITH A DEDUPE BY EVENT ID, BECAUSE OVERLAP IS PART OF THE CONTRACT.
    /// The server windows messages and calls independently and merges afterwards, so
    /// one cursor point can sit inside one source's window and past the other's, and
    /// sending it back re-reads rows this client already holds. Appending blind shows
    /// the operator the same message twice, and a duplicate id in a `ForEach` is a
    /// rendering fault rather than a cosmetic repeat.
    ///
    /// ⛔ THE THREAD STAYS ON SCREEN WHEN THIS FAILS. Failing to read a page BEHIND
    /// the conversation is no reason to take the conversation away; the failure sits
    /// at the top where the tap happened and the control remains.
    func loadOlder() async {
        guard let selector = target.selector, var content = current else { return }
        guard !content.loadingOlder, content.hasMore, let cursor = content.cursor else { return }

        content.loadingOlder = true
        content.olderFailure = nil
        setContent(content)

        let outcome = await inbox.timeline(workspaceId: target.workspaceId, selector: selector, cursor: cursor)
        guard var latest = current else { return }
        latest.loadingOlder = false
        switch outcome {
        case let .success(page):
            latest.events = Self.merge(held: latest.events, older: page.events)
            // ⚠️ ADOPTED FROM THE NEW PAGE, NOT ANDed WITH THE OLD ONE. An empty page
            // reports `hasMore = false` and no cursor, which is exactly the end of
            // the thread; the earlier `hasMore` was allowed to have been optimistic.
            latest.hasMore = page.hasMore
            latest.cursor = page.cursor
            latest.incompleteCount += page.droppedEventCount
        case let .failure(error):
            latest.olderFailure = FailureText.from(error)
        }
        setContent(latest)
    }

    // MARK: - The composer

    /// Record an edit and (re)arm the autosave.
    ///
    /// ⚠️ THE DEBOUNCE IS RESTARTED, NOT EXTENDED FROM THE FIRST EDIT. A sustained
    /// typist would otherwise never save at all. ``armAutosave(_:)`` is the timer,
    /// shared with ``subjectChanged(_:)``.
    func composerTextChanged(_ text: String) {
        composerText = text
        armAutosave(text)
    }

    /// Put a restored draft in the box WITHOUT arming an autosave.
    ///
    /// ⛔ THE ONLY REASON ``composerText``'s SETTER IS NOT FULLY PRIVATE. `private(set)`
    /// is file-scoped and ``restoreDraft()`` lives in a sibling file. Every other write
    /// goes through ``composerTextChanged(_:)``; this one must not arm a debounce, which
    /// would save back the exact bytes just read.
    func adoptDraft(_ text: String) {
        composerText = text
    }

    /// Record a subject edit and (re)arm the autosave.
    ///
    /// ⚠️ IT ARMS THE SAME ONE ``composerTextChanged(_:)`` DOES, on the current body,
    /// because the draft row holds both columns and a subject typed after the last
    /// keystroke would otherwise never be written.
    func subjectChanged(_ subject: String) {
        composerSubject = subject
        armAutosave(composerText)
    }

    /// Put a subject in the box WITHOUT arming an autosave.
    ///
    /// ⛔ THE SECOND REASON ``composerSubject``'s SETTER IS NOT FULLY PRIVATE, and the
    /// same one ``adoptDraft(_:)`` gives: `private(set)` is file-scoped and both
    /// non-arming writers live in sibling files. Neither may arm a debounce — the
    /// restore would save back the bytes it has just read, and the seeded `Re:` would
    /// spend one of the workspace's 60 writes/min on a line this client derived rather
    /// than the operator typed.
    func adoptSubject(_ subject: String) {
        composerSubject = subject
    }

    /// Send a reply, with whatever is attached.
    ///
    /// ⛔ GUARDED AGAINST A SECOND TAP WHILE ONE IS IN FLIGHT, AND THAT GUARD IS ABOUT
    /// MONEY. Every send is billable carrier segments or a Postmark send and the
    /// server caps a workspace at 30/min, so a double tap must not become two charges
    /// and a message the customer receives twice.
    ///
    /// ⛔ REFUSES AN EMPTY BODY EVEN WITH AN IMAGE ATTACHED. `messages/send` guards on
    /// `!body` BEFORE it looks at `mediaUrls`, so a picture with no caption is a 400
    /// rather than a message.
    ///
    /// ⚠️ ON SUCCESS THE THREAD IS RE-READ RATHER THAN APPENDED TO LOCALLY. The sent
    /// row gets its id, status and timestamp from the server, and a locally invented
    /// bubble would show a delivery status this client made up — the one thing an
    /// operator is actually checking after a send.
    ///
    /// ⛔ AND IT REFUSES AN EMAIL WITH NO SUBJECT, which is ``canSendNow``'s other
    /// half. Sending one is not an error the server reports: it substitutes
    /// "Message from District" and delivers, so the operator learns nothing and the
    /// customer's mail client threads the reply onto the wrong conversation.
    func send() async {
        guard canReply, let recipient = target.replyTarget else { return }
        guard var content = current, !content.sending, canSendNow else { return }
        let body = composerText
        let media = content.attachments

        content.sending = true
        content.sendFailure = nil
        setContent(content)

        let outcome = await inbox.send(
            workspaceId: target.workspaceId,
            target: recipient,
            body: body,
            subject: outgoingSubject,
            mediaUrls: media
        )
        switch outcome {
        case .success:
            await finishSend()
        case let .failure(error):
            // ⚠️ THE CONVERSATION STAYS, AND SO DO THE ATTACHMENTS. They are already
            // uploaded, and dropping them would make a retry re-pick every image.
            // ⛔ NOTHING IS RE-SENT AUTOMATICALLY: a timeout means the send may well
            // have landed, and a second attempt is a second charge.
            guard var latest = current else { return }
            latest.sending = false
            latest.sendFailure = FailureText.from(error)
            setContent(latest)
        }
    }

    /// Ask the model for a reply and put it in the composer.
    ///
    /// ⛔ BILLED, NON-IDEMPOTENT, AND ONE EXPLICIT TAP ONLY — one Vertex generation
    /// per invocation, 20/min per workspace, with no entitlement check in front of
    /// it. It must never be fired from a timer, a retry helper, an autosave debounce
    /// or a view's appearance, and it is guarded against a double tap for the same
    /// reason ``send()`` is.
    ///
    /// ⛔ THE GENERATED TEXT IS TREATED EXACTLY AS IF THE OPERATOR HAD TYPED IT, so it
    /// autosaves like anything else. Holding it un-persisted would make the composer
    /// lie: the box would show text that a process death silently discards.
    ///
    /// ⚠️ AN EMPTY GENERATION IS DISCARDED RATHER THAN WRITTEN. The route answers `""`
    /// when the model returns nothing, and blanking a composer the operator had typed
    /// in is the single most destructive thing this button could do.
    func generateDraft() async {
        guard canReply, let selector = target.selector else { return }
        guard var content = current, !content.draftGenerating else { return }
        content.draftGenerating = true
        content.sendFailure = nil
        setContent(content)

        let outcome = await inbox.generateDraft(workspaceId: target.workspaceId, selector: selector)
        guard var latest = current else { return }
        latest.draftGenerating = false
        switch outcome {
        case let .success(text):
            setContent(latest)
            if !Self.isBlank(text) {
                composerTextChanged(text)
            }
        case let .failure(error):
            latest.sendFailure = FailureText.from(error)
            setContent(latest)
        }
    }

    /// Dismiss a send, attach or generation failure without disturbing the thread.
    func dismissFailure() {
        guard var content = current else { return }
        content.sendFailure = nil
        setContent(content)
    }

    /// ⛔ A BLANK BOX SENDS DELETE, NEVER A PUT WITH AN EMPTY BODY. The route answers
    /// 400 `empty_body` to the latter, deliberately, because a blank draft is the
    /// ABSENCE of one rather than an empty one — and a stored blank row would make
    /// the Inbox badge count a thread with nothing to restore. The two writes share
    /// one rate-limit bucket, so getting this wrong also burns a slot to be refused.
    ///
    /// - Returns: true when the blank case was handled and nothing else should write.
    func deleteDraftIfBlank(_ text: String) async -> Bool {
        guard Self.isBlank(text) else { return false }
        _ = await inbox.deleteDraft(workspaceId: target.workspaceId, threadKey: target.threadKey)
        return true
    }

    // MARK: - Internals

    /// ⛔ THE PENDING AUTOSAVE IS CANCELLED FIRST. Without this a debounce armed by
    /// the last keystroke fires AFTER the delete and re-creates the draft that was
    /// just sent, which is the duplicate-reply bug in slow motion.
    ///
    /// ⚠️ AND THE SERVER DRAFT IS DELETED, NOT LEFT TO EXPIRE. A draft that survives
    /// its own send is a message the operator sends twice on their next device.
    private func finishSend() async {
        autosaveTask?.cancel()
        autosaveTask = nil
        composerText = ""
        // ⚠️ AND THE SUBJECT WITH IT, so the next reply on this thread re-derives
        // its own `Re:` from the message that has just been added rather than
        // inheriting the one that went out.
        composerSubject = ""
        _ = await inbox.deleteDraft(workspaceId: target.workspaceId, threadKey: target.threadKey)
        await load()
        seedSubjectIfNeeded()
    }

    /// The debounce's body.
    ///
    /// ⚠️ THE ATTACHMENTS AND THE SUBJECT ARE READ AT FIRE TIME, NOT AT EDIT TIME:
    /// an image attached, or a subject typed, during the debounce belongs on the
    /// draft the timer is about to write.
    ///
    /// ⚠️ INTERNAL RATHER THAN `private` FOR ``flushDraft()``; see ``autosaveTask``.
    func persistDraft(_ text: String) async {
        if await deleteDraftIfBlank(text) {
            return
        }
        _ = await inbox.saveDraft(
            workspaceId: target.workspaceId,
            threadKey: target.threadKey,
            body: text,
            subject: outgoingSubject,
            mediaUrls: current?.attachments ?? []
        )
    }

    /// The loaded content, whether or not the thread has any events.
    ///
    /// ⚠️ INTERNAL RATHER THAN `private` FOR ``restoreDraft()``; see ``autosaveTask``.
    var current: ThreadContent? {
        switch state {
        case let .content(content), let .empty(content):
            content
        case .loading, .failed:
            nil
        }
    }

    /// ⚠️ THE EMPTY/CONTENT SPLIT IS DERIVED HERE AND NOWHERE ELSE, so the two cases
    /// can never disagree with the events they carry.
    ///
    /// ⚠️ INTERNAL RATHER THAN `private` FOR ``restoreDraft()``; see ``autosaveTask``.
    func setContent(_ content: ThreadContent) {
        state = content.events.isEmpty ? .empty(content) : .content(content)
    }

    /// ⛔ THE COPY ALREADY ON SCREEN WINS A COLLISION. Both are the same row from the
    /// same server, so neither is fresher, and replacing it would recompose a bubble
    /// the operator is looking at for no visible change.
    ///
    /// ⚠️ RE-SORTED AFTER THE MERGE RATHER THAN CONCATENATED. Concatenation is only
    /// correct if every event of the older page precedes every event held, which is
    /// what the cursor promises about a server this client cannot see; the cost of
    /// being wrong is a conversation that reads out of order.
    ///
    /// ⚠️ THE TIMESTAMP IS COMPARED AS A STRING, WHICH IS CHRONOLOGICAL ONLY BECAUSE
    /// THE SERVER EMITS ONE FIXED-WIDTH ISO-8601 FORM for every row. This client owns
    /// no date parsing, for the reason ``MessageDraft/updatedAt`` documents; the id
    /// tiebreak matches the server's own total order.
    static func merge(held: [ThreadEvent], older: [ThreadEvent]) -> [ThreadEvent] {
        var seen = Set(held.map(\.id))
        var merged = held
        for event in older {
            guard !seen.contains(event.id) else { continue }
            seen.insert(event.id)
            merged.append(event)
        }
        return merged.sorted { lhs, rhs in
            lhs.timestamp == rhs.timestamp ? lhs.id < rhs.id : lhs.timestamp < rhs.timestamp
        }
    }

    /// ⚠️ INTERNAL RATHER THAN `private` FOR ``canSendNow``; see ``autosaveTask``.
    static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// ⛔ NOT A RETRY. A thread key in neither documented form is a malformed
    /// destination, and asking for it again produces the identical nothing.
    private static let unopenable = FailureText(
        message: "This conversation could not be opened.",
        action: .none
    )
}
