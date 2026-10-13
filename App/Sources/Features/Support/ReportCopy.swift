import DistrictModel
import Foundation

/// Every word the report sheet uses, and the two strings that reach the desk.
///
/// ⛔ ITS OWN FILE BECAUSE THE SUBJECT AND THE MESSAGE ARE A CONTRACT, NOT COPY. The
/// subject is what a human triaging the desk sorts on, the recording suffix is what
/// lets them close the tickets a review recording filed, and the message is the only
/// place the reported thread or call id exists — the payload may carry nothing else
/// (see the ⛔ on ``ReportContentModel``). A literal buried in a view could not be
/// pinned by a test, and `ReportCopyTests` pins all three.
enum ReportCopy {
    /// The subject this build sends.
    ///
    /// ⚠️ READ PER CALL RATHER THAN STORED, because the discriminator is a launch
    /// argument and a `static let` would be resolved once at first use — which on a
    /// relaunched app is whichever launch happened to touch it first.
    static var subject: String {
        ReviewRecordingMode.isArmed() ? baseSubject + recordingSuffix : baseSubject
    }

    // MARK: - The sheet

    static func confirmation(for filing: SupportRequestFiling) -> String {
        switch filing {
        case .filed:
            accepted
        case .deduplicated:
            alreadyReported
        case .pending:
            pending
        }
    }

    // MARK: - What the desk receives

    static func headline(for target: ReportTarget) -> String {
        switch target {
        case let .conversation(_, name):
            // ⚠️ THE RESOLVED NAME MAY BE A NUMBER OR THE LITERAL "Unknown", which
            // the voice agent writes for an unidentified caller — so a nil-coalesce
            // to a neutral noun is the only safe fallback. See
            // ``Contact/displayName``.
            name.map { headlineConversationWith($0) } ?? headlineConversation
        case .call:
            headlineCall
        }
    }

    /// The message body.
    ///
    /// ⛔ IT NAMES THE ID AND QUOTES NO CONTENT. A support request is a Jira issue at
    /// a vendor whose published sub-processor row does not cover customer conversation
    /// content, and an agent who needs to read the thread can read it in the
    /// workspace under that workspace's own access rules. Copying a transcript in
    /// would move the content out of its residency region to save one click.
    ///
    /// ⚠️ THE BLANK-NOTE CASE SAYS SO EXPLICITLY. An empty tail would leave an agent
    /// wondering whether the note failed to send; "No note was added." is the
    /// difference between an absent field and a lost one.
    ///
    /// ⚠️ 1...10000 CHARACTERS, SERVER-VALIDATED. The note is the only unbounded part
    /// and the sheet caps it; see ``noteLimit``.
    static func message(for target: ReportTarget, note: String) -> String {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = trimmed.isEmpty ? noNote : trimmed
        return "\(preamble)\n\(reference(for: target))\n\n\(tail)"
    }

    /// ⚠️ THE KEY AS THE APP HOLDS IT, PREFIX AND ALL. `contact:<id>` and
    /// `addr:<normalized>` are the drafts table's own vocabulary, so an agent can
    /// paste it straight into a query; stripping the prefix would produce an id that
    /// matches two different tables.
    static func reference(for target: ReportTarget) -> String {
        switch target {
        case let .conversation(threadKey, _):
            referenceConversation(threadKey)
        case let .call(callId):
            referenceCall(callId)
        }
    }

    /// ⚠️ WELL UNDER THE ROUTE'S 10000, because the preamble and the reference share
    /// the budget and a note is a sentence rather than a document. Mirrored
    /// client-side so an over-long note is refused in the sheet rather than 400-ing
    /// after the claim row exists. ⛔ A mirror, not an authority: if the two ever
    /// disagree the server is right and this constant is what moves.
    static let noteLimit = 2000
}
