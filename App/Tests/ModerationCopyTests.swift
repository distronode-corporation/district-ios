@testable import DistrictAI
import DistrictModel
import XCTest

/// The App Store Review Guideline 1.2 copy, above the package boundary Linux cannot
/// reach.
///
/// ⛔ THESE ARE NOT COSMETIC ASSERTIONS. Guideline 1.2 asks an app with user-generated
/// content for three mechanisms: the terms presented BEFORE sign-in, a way to flag
/// objectionable content, and a way to block the person who produced it. The sentence
/// under the sign-in controls and the subject line that reaches the support desk are
/// the two strings a reviewer and a triaging human read, and both are assembled from
/// fragments — so a reword that broke the assembly would be invisible to every other
/// gate in this repo.
///
/// ⚠️ IN `App/Tests` RATHER THAN `DistrictCore`, because that is where they live:
/// `ReportCopy`, `SignInTermsCopy` and `ContactBlockCopy` are App-target types (the
/// first reads a launch argument, the other two are read by SwiftUI views), and
/// `project.yml`'s own rule is that logic which CAN live in DistrictCore does and the
/// bundle is for what cannot.
final class ModerationCopyTests: XCTestCase {
    // MARK: - The terms line (Guideline 1.2, before sign-in)

    /// ⛔ THE WHOLE SENTENCE, BYTE FOR BYTE. It is rendered as a `Text` plus two
    /// `Button`s so each legal page is separately tappable, so nothing on screen
    /// holds the sentence — this is the only place its composition is checked.
    func testTheTermsSentenceReadsAsOneSentence() {
        XCTAssertEqual(
            SignInTermsCopy.sentence,
            "By continuing you agree to the Terms of Service and Privacy Policy."
        )
    }

    /// ⚠️ THE LINK NAMES ARE ALSO THE PAGE TITLES AND THE STORE LISTING'S OWN FIELD
    /// NAMES, so they are asserted separately from the sentence: a reword that kept
    /// the sentence grammatical while renaming a control would still break the
    /// recording's shot list.
    func testTheTwoLegalPagesAreNamedAsApplesMetadataNamesThem() {
        XCTAssertEqual(SignInTermsCopy.termsName, "Terms of Service")
        XCTAssertEqual(SignInTermsCopy.privacyName, "Privacy Policy")
    }

    /// ⛔ FULL, PUBLIC, PRODUCTION URLS. They must resolve for a reviewer with no
    /// session and no build config; a path on the API base would not.
    func testTheLegalURLsArePublicAndAbsolute() throws {
        let terms = try XCTUnwrap(SignInTermsCopy.termsURL)
        let privacy = try XCTUnwrap(SignInTermsCopy.privacyURL)
        XCTAssertEqual(terms.absoluteString, "https://www.distronode.com/terms")
        XCTAssertEqual(privacy.absoluteString, "https://www.distronode.com/privacy")
    }

    // MARK: - The report

    /// ⛔ THE SUBJECT A HUMAN TRIAGES ON, AND THE 3...200 BOUND THE ROUTE ENFORCES.
    func testTheReportSubjectIsWhatTheDeskSortsOn() {
        XCTAssertEqual(ReportCopy.baseSubject, "Report: objectionable content")
        XCTAssertTrue((3 ... 200).contains(ReportCopy.baseSubject.count))
        let suffixed = ReportCopy.baseSubject + ReportCopy.recordingSuffix
        XCTAssertEqual(suffixed, "Report: objectionable content (review recording)")
        XCTAssertTrue((3 ... 200).contains(suffixed.count))
    }

    /// ⛔ NOT ARMED IN AN ORDINARY TEST RUN, WHICH IS WHAT MAKES THE SUFFIX MEAN
    /// SOMETHING. If `-ReviewRecording` were read from anything the test bundle
    /// carries, every report would be marked as a recording and the marker would be
    /// worthless. ⚠️ Asserted on the DEFAULT argument list, not on an injected one.
    func testTheRecordingSuffixIsAbsentUnlessTheArgumentIsPassed() {
        XCTAssertEqual(ReportCopy.subject, ReportCopy.baseSubject)
    }

    #if DEBUG
        func testTheRecordingArgumentArmsTheSuffix() {
            XCTAssertTrue(ReviewRecordingMode.isArmed(arguments: ["app", "-ReviewRecording"]))
            XCTAssertFalse(ReviewRecordingMode.isArmed(arguments: ["app", "-UITestSession"]))
            XCTAssertEqual(ReviewRecordingMode.launchArgument, "-ReviewRecording")
        }
    #endif

    /// ⛔ THE MESSAGE NAMES THE THREAD AND QUOTES NO CONTENT. A support request is a
    /// Jira issue at a vendor whose subprocessor row does not cover customer
    /// conversation content; an agent who needs the thread reads it in the workspace.
    func testTheReportMessageNamesTheThreadAndCarriesTheNote() {
        let message = ReportCopy.message(
            for: .conversation(threadKey: "contact:c_1", name: "Casey"),
            note: "  Abusive language.  "
        )

        XCTAssertTrue(message.hasPrefix(ReportCopy.preamble))
        XCTAssertTrue(message.contains("Conversation: contact:c_1"))
        // ⚠️ TRIMMED, so leading whitespace from a phone keyboard does not become the
        // first thing an agent reads.
        XCTAssertTrue(message.hasSuffix("Abusive language."))
        // ⛔ THE NAME IS NOT ON THE WIRE. It is the sheet's heading only; the payload
        // may carry nothing beyond kind, subject, message and the key, because the
        // desk 400s an unknown field AFTER the local claim row exists.
        XCTAssertFalse(message.contains("Casey"))
    }

    func testTheReportMessageNamesTheCall() {
        let message = ReportCopy.message(for: .call(callId: "call_9"), note: "")
        XCTAssertTrue(message.contains("Call: call_9"))
    }

    /// ⛔ A BLANK NOTE SAYS SO RATHER THAN LEAVING AN EMPTY TAIL. An absent field and
    /// a lost one look identical to the agent reading the ticket.
    func testABlankNoteIsStatedRatherThanLeftEmpty() {
        let message = ReportCopy.message(for: .call(callId: "call_9"), note: "   \n ")
        XCTAssertTrue(message.hasSuffix("No note was added."))
    }

    /// ⛔ THE THREAD KEY GOES ON THE WIRE WITH ITS PREFIX. `contact:` and `addr:` are
    /// the drafts table's own vocabulary; stripping the prefix would produce an id
    /// that matches two different tables.
    func testTheThreadKeyKeepsItsPrefix() {
        XCTAssertEqual(
            ReportCopy.reference(for: .conversation(threadKey: "addr:14165550123", name: nil)),
            "Conversation: addr:14165550123"
        )
    }

    /// ⛔ ALL THREE SUCCESSFUL FILINGS GET A SENTENCE, AND NONE OF THEM READS AS A
    /// FAILURE. Reporting `deduplicated` as an error is what invites a second
    /// moderation ticket into a human's queue.
    func testEverySuccessfulFilingHasItsOwnSentence() {
        XCTAssertEqual(ReportCopy.confirmation(for: .filed(issueKey: "DA-42")), "Reported. We'll review it.")
        XCTAssertEqual(ReportCopy.confirmation(for: .deduplicated), ReportCopy.alreadyReported)
        XCTAssertEqual(ReportCopy.confirmation(for: .pending), ReportCopy.pending)
        XCTAssertNotEqual(ReportCopy.alreadyReported, ReportCopy.accepted)
    }

    /// ⚠️ THE CONFIRMATION IS A FIXED SENTENCE, and it is what a reviewer sees on the
    /// recording.
    func testTheAcceptedSentenceIsTheOneOnTheRecording() {
        XCTAssertEqual(ReportCopy.accepted, "Reported. We'll review it.")
    }

    /// ⚠️ THE CONTROLS NAME THE CONTENT. "Report" alone beside a conversation reads
    /// as "report on it".
    func testTheReportControlsNameWhatTheyFlag() {
        XCTAssertEqual(ReportCopy.reportConversation, "Report conversation")
        XCTAssertEqual(ReportCopy.reportCall, "Report call")
    }

    /// ⚠️ THE HEADING CARRIES THE RESOLVED NAME WHEN THERE IS ONE AND DEGRADES TO A
    /// NEUTRAL QUESTION WHEN THERE IS NOT — never to "Unknown", which the voice agent
    /// writes for an unidentified caller and which would read as a name.
    func testTheSheetHeadingDegradesWithoutAName() {
        XCTAssertEqual(
            ReportCopy.headline(for: .conversation(threadKey: "contact:c_1", name: "Casey")),
            "Report this conversation with Casey?"
        )
        XCTAssertEqual(
            ReportCopy.headline(for: .conversation(threadKey: "addr:1416", name: nil)),
            "Report this conversation?"
        )
        XCTAssertEqual(ReportCopy.headline(for: .call(callId: "call_1")), "Report this call?")
    }

    // MARK: - The block

    /// ⛔ THE PROMPT SAYS WHAT BLOCKING DOES AND THAT IT IS REVERSIBLE, which is the
    /// difference between this dialog and the delete one beside it on the same screen.
    func testTheBlockPromptStatesTheEffectAndTheUndo() {
        XCTAssertTrue(ContactBlockCopy.blockPrompt.contains("stop appearing in this workspace"))
        XCTAssertTrue(ContactBlockCopy.blockPrompt.contains("unblock them here at any time"))
    }

    /// ⛔ IT DOES NOT CLAIM THE CALLER CANNOT REACH THE WORKSPACE. Blocking hides
    /// threads and calls from these screens; it does not stop a phone ringing at a
    /// carrier, and wording it as "they can no longer contact you" would be a promise
    /// the estate does not keep.
    func testTheBlockPromptDoesNotPromiseTheCallerCannotReachYou() {
        for sentence in [ContactBlockCopy.blockPrompt, ContactBlockCopy.unblockPrompt] {
            XCTAssertFalse(sentence.lowercased().contains("cannot contact"))
            XCTAssertFalse(sentence.lowercased().contains("no longer contact"))
            XCTAssertFalse(sentence.lowercased().contains("will not be able to call"))
        }
    }

    /// ⚠️ THE DIALOG'S BUTTON IS NOT THE CONTROL THAT OPENED IT. The same word twice
    /// reads as a dialog that had not registered the first tap.
    func testTheConfirmButtonIsNotTheControlLabel() {
        XCTAssertNotEqual(ContactBlockCopy.confirmBlock, ContactBlockCopy.block)
        XCTAssertNotEqual(ContactBlockCopy.confirmUnblock, ContactBlockCopy.unblock)
        XCTAssertEqual(ContactBlockCopy.block, "Block caller")
        XCTAssertEqual(ContactBlockCopy.unblock, "Unblock caller")
        XCTAssertEqual(ContactBlockCopy.badge, "Blocked")
    }

    /// ⛔ THE UNBLOCK IS CONFIRMED TOO, so its prompt has to exist and has to say that
    /// content comes BACK. An unconfirmed unblock is content silently reappearing,
    /// which is the half that is easy to forget.
    func testTheUnblockPromptSaysContentComesBack() {
        XCTAssertTrue(ContactBlockCopy.unblockPrompt.contains("start appearing in this workspace again"))
    }
}
