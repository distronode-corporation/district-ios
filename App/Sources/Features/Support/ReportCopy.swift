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
    /// ⛔ 3...200 CHARACTERS, SERVER-VALIDATED, AND THE SUFFIXED FORM MUST ALSO FIT.
    /// Both are well inside it; the bound is stated so a future reword checks.
    static let baseSubject = "Report: objectionable content"

    /// ⛔ THE MARKER A HUMAN CLOSES ON. A recording's report is about a fictional
    /// `+1 555 01xx` caller in the demo workspace, so it is not a moderation case —
    /// but it IS a real ticket in a real queue, and an unmarked one would be triaged
    /// as if the content existed.
    static let recordingSuffix = " (review recording)"

    /// The subject this build sends.
    ///
    /// ⚠️ READ PER CALL RATHER THAN STORED, because the discriminator is a launch
    /// argument and a `static let` would be resolved once at first use — which on a
    /// relaunched app is whichever launch happened to touch it first.
    static var subject: String {
        ReviewRecordingMode.isArmed() ? baseSubject + recordingSuffix : baseSubject
    }

    // MARK: - The sheet

    /// ⛔ THE CONTROL NAMES THE CONTENT, NOT THE MECHANISM. "Report" alone beside a
    /// conversation reads as "report on it", and a reviewer looking for a flag has to
    /// be able to find it without guessing. Two strings because the two screens hold
    /// two different kinds of content, and both are what Apple's shot list calls them.
    static let reportConversation = "Report conversation"
    static let reportCall = "Report call"

    static let title = "Report content"
    static let submit = "Report"
    static let cancel = "Cancel"
    static let notePrompt = "Add a note (optional)"
    static let noteLabel = "What is wrong with it?"

    /// ⛔ THE CONFIRMATION APP REVIEW ASKS FOR. Apple's ask is
    /// that the reviewer SEE the flag being accepted; a sheet that dismissed silently
    /// would be indistinguishable on video from one that failed.
    static let accepted = "Reported. We'll review it."

    /// ⚠️ THE OTHER TWO SUCCESSFUL OUTCOMES GET THEIR OWN SENTENCE. Both mean "we
    /// have it", and reporting either as a failure is what invites a second ticket.
    static let alreadyReported = "You have already reported this. We'll review it."
    static let pending = "Reported. We have it and it is catching up."

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
            "Report this conversation\(name.map { " with \($0)" } ?? "")?"
        case .call:
            "Report this call?"
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
        let tail = trimmed.isEmpty ? "No note was added." : trimmed
        return "\(preamble)\n\(reference(for: target))\n\n\(tail)"
    }

    /// ⛔ IT SAYS WHERE THE REPORT CAME FROM, because the same desk receives requests
    /// raised from the contact form and from an unresolved phone call (the wire field
    /// is `source`), and a moderation report needs telling apart from a support
    /// question at a glance.
    static let preamble = "Objectionable content was reported from the District AI iOS app."

    /// ⚠️ THE KEY AS THE APP HOLDS IT, PREFIX AND ALL. `contact:<id>` and
    /// `addr:<normalized>` are the drafts table's own vocabulary, so an agent can
    /// paste it straight into a query; stripping the prefix would produce an id that
    /// matches two different tables.
    static func reference(for target: ReportTarget) -> String {
        switch target {
        case let .conversation(threadKey, _):
            "Conversation: \(threadKey)"
        case let .call(callId):
            "Call: \(callId)"
        }
    }

    /// ⚠️ WELL UNDER THE ROUTE'S 10000, because the preamble and the reference share
    /// the budget and a note is a sentence rather than a document. Mirrored
    /// client-side so an over-long note is refused in the sheet rather than 400-ing
    /// after the claim row exists. ⛔ A mirror, not an authority: if the two ever
    /// disagree the server is right and this constant is what moves.
    static let noteLimit = 2000
}
