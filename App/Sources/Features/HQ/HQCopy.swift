import Foundation

/// Every sentence District HQ says on this client.
///
/// ⚠️ ITS OWN FILE RATHER THAN AN EXTENSION AT THE BOTTOM OF `HQView.swift`, AND THAT
/// IS A LINT CEILING RATHER THAN A DESIGN STATEMENT, the same call ``DialerCopy`` and
/// ``OverviewEntry`` make. `swiftlint --strict` promotes the `file_length` WARNING at
/// 500 lines to an error.
///
/// ⚠️ HOISTED TO `String` CONSTANTS RATHER THAN WRITTEN INLINE, for the reason
/// `DevicesView` records: a literal handed straight to an API carrying both a
/// `LocalizedStringKey` and a `StringProtocol` overload is an inference question at the
/// call site, and the error lands far from the literal.
///
/// ⛔ THE COPY IS ANDROID'S, WORD FOR WORD WHERE ANDROID HAS A STRING. Two clients
/// answering "did that change apply" with two different sentences is how one of them
/// ends up wrong; the Android client's string resources are the source.
enum HQCopy {
    static let title = "District HQ"

    static let emptyTitle = "Ask District HQ"

    /// ⚠️ NAMES THE FOUR THINGS THE TOOL CATALOG CAN ANSWER FROM. A vaguer invitation
    /// ("ask me anything") sets up questions the tools cannot serve, and the model is
    /// instructed to refuse rather than invent, so the empty state would be generating
    /// its own dead ends.
    static let empty = "Ask about your calls, contacts, the AI receptionist, or your knowledge base."

    static let promptLabel = "Ask"

    static let send = "Send"

    /// ⚠️ A LABEL RATHER THAN A SPINNER, matching the reply box: the composer is
    /// disabled while a turn runs, so something has to say why.
    static let thinking = "Thinking…"

    static let confirmTitle = "Confirm this change"

    /// ⛔ THE LOAD-BEARING SENTENCE ON THIS WHOLE SCREEN. The answer above the card says
    /// a change was PROPOSED; without this line a proposal reads as a completed action
    /// and the operator leaves believing it was applied. It is the client half of the
    /// server's own rule that a write happens only on an explicit second call.
    ///
    /// ⛔ AND IT IS TRUE ONLY BEFORE THE FIRST CONFIRM. After one fails it becomes a
    /// claim nobody can make, which is why ``confirmFailedNote`` replaces it rather than
    /// sitting beside it. See ``HQConsoleState/confirmFailed(_:_:)``.
    static let confirmNote = "Nothing has been changed yet."

    /// ⛔ REPLACES ``confirmNote`` ONCE A CONFIRM HAS FAILED, BECAUSE THAT SENTENCE IS NO
    /// LONGER KNOWN TO BE TRUE. A confirm that timed out may already have executed
    /// server-side — it is the reason nothing retries one automatically — so keeping
    /// "Nothing has been changed yet." directly above a button labelled "Confirm again"
    /// would contradict the button. This says what the button's label already implies.
    static let confirmFailedNote = "That attempt failed. It may already have been applied, so check "
        + "before confirming again."

    /// ⛔ WHY THE COMPOSER IS CLOSED WHILE A PROPOSAL IS ON SCREEN. Sending a new prompt
    /// would replace the console state and destroy the card, the summary and the
    /// pending write, with nothing recoverable: none of it is in the transcript and the
    /// confirm route accepts only a proposal that came back from a prompt. Both ways out
    /// are one tap on the card immediately above this line.
    static let composerBlocked = "Confirm or dismiss the change above before asking something else."

    static let confirmApply = "Confirm"

    static let confirmRetry = "Confirm again"

    static let confirmDismiss = "Dismiss"

    static let applying = "Applying…"

    static let applied = "Applied."

    /// ⛔ SAYS "NOT APPLIED", NOT "FAILED". The server answers `success` with
    /// `executed: false` when it handled the request and DECLINED the write (a
    /// view-only role, or a tool that refused internally). Reporting that as an error
    /// would be wrong, and reporting it as done would be worse.
    static let notApplied = "That change was not applied."

    static let retry = "Try again"

    /// ⚠️ SHOWN UNDER THE PROPOSAL FOR A ROLE THE SERVER WOULD REFUSE, in place of the
    /// Confirm button. A viewer should not normally see a proposal at all (the tool
    /// executor declines their write before the confirmation gate is reached), so this
    /// exists for the case where that ordering changes, and it says who can apply the
    /// change rather than leaving a card with only a Dismiss button on it.
    static let viewerCannotConfirm = "You are in this workspace as a viewer, "
        + "so ask an agency or client member to apply this."
}
