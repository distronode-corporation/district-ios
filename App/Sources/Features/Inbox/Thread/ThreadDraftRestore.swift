import DistrictData
import DistrictModel
import Foundation

/// Opening the thread, and adopting whatever reply is already saved on it.
///
/// ⛔ A SIBLING FILE FOR THE REASON `ThreadDraftFlush.swift` GIVES, AND THE SAME GATE
/// FORCES IT. `ThreadModel.swift` runs close to the 500 lines `swiftlint --strict`
/// allows (`file_length` warns at 500 and every warning is an error in CI), so the
/// rules below do not fit beside the rest of the model. The alternative is the code
/// with none of its reasoning, which is the trade this codebase does not make. The
/// ceiling keeps being reached, so it is not a solved problem.
///
/// ⚠️ WHAT THE SPLIT COSTS, LISTED SO IT CANNOT QUIETLY GROW. ``ThreadModel/inbox``,
/// ``ThreadModel/target``, ``ThreadModel/draftRestored``, ``ThreadModel/current`` and
/// ``ThreadModel/setContent(_:)`` are not `private`; App is one module and there is
/// no second reader. ``ThreadModel/restorable(_:)`` needs no widening: it is used only
/// here, so it lives here. ``ThreadModel/composerText`` and
/// ``ThreadModel/composerSubject`` stay `private(set)`, which is file-scoped, so the
/// restore writes them through ``ThreadModel/adoptDraft(_:)`` and
/// ``ThreadModel/adoptSubject(_:)`` rather than by widening either property.
extension ThreadModel {
    /// The screen's whole open sequence: the newest window, the saved draft, then the
    /// subject a reply would carry.
    ///
    /// ⚠️ SEQUENTIAL, AND THE DRAFT READ IS SECOND. The restore writes its attachments
    /// into the loaded content, so it has to run after there is content to write into.
    /// Its text half survives a failed load either way.
    ///
    /// ⛔ THE SUBJECT SEED IS LAST BECAUSE IT DEFERS TO BOTH. A stored draft's own
    /// subject is what the operator last typed and wins; the `Re:` derived from the
    /// thread only fills a box that is still empty. See ``seedSubjectIfNeeded()``.
    ///
    /// ⛔ IT IS ONE METHOD RATHER THAN TWO CALLS IN THE VIEW BECAUSE THE SCREEN'S RETRY
    /// HAS TO RUN BOTH HALVES. A "Try again" that re-read the timeline alone would leave
    /// a thread whose FIRST open failed with a composer that never learned about the
    /// saved draft: `.task` has already completed, so nothing would call the restore
    /// again for the life of the screen, and the operator would type over a reply they
    /// could not see. ``restoreDraft()`` is idempotent by its own latch, so running it
    /// on every retry costs one request only when there is still no answer.
    func open() async {
        await load()
        recordRead()
        await restoreDraft()
        seedSubjectIfNeeded()
    }

    /// Tell the workspace this thread has been seen.
    ///
    /// ⛔ ON THE SCREEN THAT OPENED, NOT ON THE ROW THAT WAS TAPPED, AND A DEVICE
    /// FORCES IT. A `simultaneousGesture(TapGesture())` beside the Inbox row's
    /// `NavigationLink` consumes every tap on iOS 18.7 (measured on an iPhone XS Max):
    /// the row tapped by button, by cell and by coordinate never opens the thread,
    /// while the Calls rows, which carry no gesture, push every time, and removing the
    /// gesture opens the thread on the first tap. Opening the thread IS the read, and
    /// this is the one place that knows it opened.
    ///
    /// ⚠️ AFTER A SUCCESSFUL LOAD ONLY. A thread that could not be read has not been
    /// seen, and clearing a colleague's badge for it would say otherwise.
    ///
    /// ⚠️ OPTIMISTIC AND NOT AWAITED: if the write fails
    /// the badge is stale until the next list read, which is cosmetic, and blocking
    /// the screen on bookkeeping would slow the common case to serve the rare one.
    /// ``ThreadModel/canMutate`` gates it because `messages/mark-read` excludes
    /// `viewer`, so the app never fires a known 403.
    ///
    /// ⚠️ THE TASK CAPTURES VALUES, NEVER `self`. ``InboxRepository`` is a `Sendable`
    /// struct and ``ThreadSelector`` a `Sendable` enum; this model is `@MainActor`.
    func recordRead() {
        guard canMutate, !readRecorded, current != nil else { return }
        guard let selector = target.selector else { return }
        readRecorded = true
        let repository = inbox
        let workspaceId = target.workspaceId
        Task { _ = await repository.markRead(workspaceId: workspaceId, selector: selector) }
    }

    /// Adopt the server's draft, once, on open.
    ///
    /// ⛔ THE LOCAL BOX WINS WHEN IT IS NOT EMPTY, AND THE RULE IS DELIBERATELY THAT
    /// SIMPLE. Adopting into an empty box can only add; overwriting a non-empty box
    /// can only lose. The next autosave then makes the server agree.
    ///
    /// ⛔ AND IT WRITES ``ThreadModel/composerText`` THROUGH
    /// ``ThreadModel/adoptDraft(_:)`` RATHER THAN THROUGH
    /// ``ThreadModel/composerTextChanged(_:)``. Going through the edit path would arm a
    /// debounce that saves back the exact bytes just read, spending one of the
    /// workspace's 60 writes/min to change nothing.
    ///
    /// ⛔ A FAILED READ AND "NO DRAFT" ARE TWO ANSWERS AND MUST NOT SHARE ONE `guard`.
    /// If offline, a 503, an expired session and a decode failure landed on the same
    /// silent `return` as the ordinary nil, with the never-retry latch already set, the
    /// composer would open empty and say nothing, and the first debounce after the
    /// operator retyped a shorter reply would upsert the same `threadKey` row and
    /// destroy the original. What makes that the worst version of the bug is that the
    /// operator has no way to know there was anything to lose.
    func restoreDraft() async {
        guard !draftRestored else { return }
        draftRestored = true
        let outcome = await inbox.draft(workspaceId: target.workspaceId, threadKey: target.threadKey)
        guard case let .success(stored) = outcome else {
            // ⛔ THE LATCH COMES BACK OFF. It is an in-flight lock as well as a "we have
            // the answer" flag, and a failure is not an answer; leaving it set would
            // make the read unrepeatable for the life of the model.
            draftRestored = false
            noteDraftUnread(outcome)
            return
        }
        // ⛔ nil IS THE ORDINARY ANSWER, NOT A FAILURE. Almost every thread has no
        // draft, and the route answers `{success, draft: null}` rather than 404
        // precisely so the composer's normal open path is not an error in every log.
        guard let draft = stored else { return }
        guard composerText.isEmpty else { return }
        adoptDraft(draft.body)
        // ⚠️ AND THE SUBJECT COMES BACK WITH IT, THROUGH THE SAME NON-ARMING WRITE.
        // The column is null on an SMS thread and can hold an empty string, so a nil
        // check alone would put a blank line in the box and then refuse the send.
        if let subject = draft.subject, !Self.isBlank(subject) {
            adoptSubject(subject)
        }
        // ⚠️ ATTACHMENTS COME BACK WITH IT. A draft saved with two images restores as
        // text plus two chips; restoring the text alone would send a message the
        // operator believed had pictures on it.
        guard !draft.mediaUrls.isEmpty, var content = current else { return }
        content.attachments = Self.restorable(draft.mediaUrls)
        setContent(content)
    }

    /// The attachments of a stored draft, made safe to render as a list.
    ///
    /// ⛔ DEDUPLICATED, IN ORDER, BECAUSE THE ROW IS A LIST OF STRINGS THE SERVER
    /// STORES AS IT WAS GIVEN THEM. Every URL this client uploads is a fresh uuid, so
    /// a repeat can only arrive from a draft written elsewhere — and a duplicate id
    /// inside one `ForEach` is a rendering fault rather than a cosmetic repeat.
    ///
    /// ⚠️ CAPPED AT THE SEND CEILING TOO, so a draft holding six (the drafts route
    /// allows five, but this client must not depend on that) cannot produce a
    /// composer whose send is refused before it starts.
    ///
    /// ⚠️ IT LIVES BESIDE ITS ONLY CALLER RATHER THAN ON THE MODEL. That is a
    /// `file_length` decision as much as a cohesion one: `ThreadModel.swift` sits
    /// within a few lines of the 500 `swiftlint --strict` allows, and the composer's
    /// subject had to go somewhere.
    static func restorable(_ urls: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        for url in urls {
            guard !seen.contains(url) else { continue }
            seen.insert(url)
            unique.append(url)
        }
        return Array(unique.prefix(maximumAttachments))
    }

    /// Say out loud that the saved reply could not be read.
    ///
    /// ⛔ THE COMPOSER IS NOT BLOCKED AND MUST NOT BE. Being unable to restore a draft
    /// is no reason to stop somebody replying to a customer, and a disabled box would
    /// turn a read failure into an outage of the one thing this screen is for. The
    /// autosave still runs and still overwrites, which is why the sentence names that
    /// consequence rather than only the failure: the operator is the one who decides
    /// whether to type now or retry first.
    ///
    /// ⚠️ THE SLOT IS ITS OWN, NOT ``ThreadContent/sendFailure``. That one is cleared by
    /// the next send, attach or generate and by its Dismiss control, so a draft failure
    /// parked in it would vanish the moment the operator did anything, which is exactly
    /// when they are about to type over the draft. It follows ``ThreadContent``'s
    /// `olderFailure` shape instead: a named field for a named read, drawn beside the
    /// control it belongs to.
    ///
    /// ⚠️ A THREAD WHOSE TIMELINE ALSO FAILED HAS NOWHERE TO PUT THIS, and that is
    /// harmless rather than swallowed: the screen is already showing its own failure and
    /// draws no composer at all, and its retry runs ``open()``, which reaches the read
    /// again with the latch still off.
    private func noteDraftUnread(_ outcome: Result<MessageDraft?, ApiError>) {
        guard case let .failure(error) = outcome, var content = current else { return }
        content.draftFailure = Self.draftUnread(error)
        setContent(content)
    }

    /// ⛔ THE MAPPED SENTENCE VERBATIM, PLUS THE CONSEQUENCE, AND THE ACTION IS
    /// ``FailureText``'s RATHER THAN THIS FUNCTION'S. `FailureText.from(_:)` already
    /// decided whether pressing again could honestly change the answer, and a decode
    /// failure gets no retry from it for the reason that type states. Re-authoring
    /// either half here would replace one rule with two.
    private static func draftUnread(_ error: ApiError) -> FailureText {
        let stated = FailureText.from(error)
        return FailureText(
            message: "\(stated.message) A reply saved on this thread could not be loaded, so the box "
                + "below may not be showing it, and anything you type will replace it.",
            action: stated.action
        )
    }
}
