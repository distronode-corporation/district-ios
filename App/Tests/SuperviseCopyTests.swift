@testable import DistrictAI
import DistrictCall
import DistrictL10n
import DistrictModel
import XCTest

/// The Live screen's sentences, in both languages: the receipt, and which sentence a refusal
/// gets.
///
/// ⛔ THE FRENCH IS ASSERTED LITERALLY, NBSP AND ALL, because the website's wording is the
/// contract: `liveI18n.ts` for the website's sentences, Sean's list for the approved ones.
final class SuperviseCopyTests: XCTestCase {
    private let nbsp = "\u{00A0}"

    func testAUsedNoteQuotesTheFirstWords() {
        let words = "  Sure, nine works.  "
        let receipt = SuperviseCopy.receipt(WhisperReceipt(applied: true, firstWords: words, reason: nil))
        XCTAssertEqual(receipt.headline, "Your receptionist used your note.")
        XCTAssertEqual(receipt.detail, "“Sure, nine works.”")

        let french = L10nRuntime.withLocale(.frCA) {
            SuperviseCopy.receipt(WhisperReceipt(applied: true, firstWords: "Oui, neuf heures.", reason: nil))
        }
        XCTAssertEqual(french.headline, "Votre réceptionniste a utilisé votre consigne.")
        XCTAssertEqual(french.detail, "«\(nbsp)Oui, neuf heures.\(nbsp)»")
    }

    func testAUsedNoteWithNoWordsHasNoSecondLine() {
        let receipt = SuperviseCopy.receipt(WhisperReceipt(applied: true, firstWords: " ", reason: nil))
        XCTAssertNil(receipt.detail)
    }

    /// ⛔ `taken_over` HAS ITS SENTENCE AND EVERY OTHER REASON IS THE TRANSFER'S, as on the
    /// website, an unknown one and a missing one included. The wire word is never shown.
    func testAHeldNoteSaysWhyInTheWebsitesWords() {
        let takenOver = SuperviseCopy.receipt(WhisperReceipt(applied: false, firstWords: "", reason: .takenOver))
        XCTAssertEqual(takenOver.headline, "Your receptionist could not use your note.")
        XCTAssertEqual(takenOver.detail, "A team member is holding the call.")
        for reason: WhisperReceipt.Reason? in [.transfer, .unknown("voicemail"), nil] {
            let receipt = SuperviseCopy.receipt(WhisperReceipt(applied: false, firstWords: "", reason: reason))
            XCTAssertEqual(receipt.detail, "The call is being transferred.", "\(String(describing: reason))")
        }
        let french = L10nRuntime.withLocale(.frCA) {
            SuperviseCopy.receipt(WhisperReceipt(applied: false, firstWords: "", reason: .takenOver)).detail
        }
        XCTAssertEqual(french, "Un membre de l'équipe a pris l'appel.")
    }

    /// ⛔ "APPROVED LINE + REASON ONLY" (Sean, 2026-11-05): exactly the two known prefixes go,
    /// what remains starts with a capital, and a sentence without a prefix is left as it was.
    func testOnlyTheKnownNotUsedPrefixesAreStripped() {
        XCTAssertEqual(
            SuperviseCopy.reasonOnly("Not used: the call is being transferred."),
            "The call is being transferred."
        )
        XCTAssertEqual(
            SuperviseCopy.reasonOnly("Consigne non utilisée\(nbsp): l'appel est en cours de transfert."),
            "L'appel est en cours de transfert."
        )
        XCTAssertEqual(SuperviseCopy.reasonOnly("The call is being transferred."), "The call is being transferred.")
        XCTAssertEqual(
            SuperviseCopy.reasonOnly("not used: lower case is not the prefix"),
            "not used: lower case is not the prefix"
        )
        XCTAssertEqual(
            SuperviseCopy.reasonOnly("Consigne non utilisée : plain space"),
            "Consigne non utilisée : plain space"
        )
        XCTAssertEqual(SuperviseCopy.reasonOnly("Not used: "), "Not used: ", "nothing after the prefix: left alone")
        XCTAssertEqual(
            SuperviseCopy.reasonOnly("Consigne non utilisée\(nbsp): écoute impossible."),
            "Écoute impossible.",
            "an accented first letter is capitalised"
        )
    }

    /// ⛔ A REFUSAL IS SAID BY ITS CODE, NEVER BY THE SERVER'S ENGLISH; an unknown code gets the
    /// action's fallback, and the phone being offline says so.
    func testARefusalIsSaidByItsCode() throws {
        let ended = ApiError.http(status: 409, message: "server words", code: "call_ended")
        XCTAssertEqual(
            SuperviseCopy.refusal(ended, fallback: "fallback"),
            try XCTUnwrap(ApiErrorText.sentence(for: "call_ended"))
        )
        let unknown = ApiError.http(status: 500, message: "boom", code: nil)
        XCTAssertEqual(SuperviseCopy.refusal(unknown, fallback: "fallback"), "fallback")
        XCTAssertEqual(SuperviseCopy.refusal(.decoding("drift"), fallback: "fallback"), "fallback")
        let offline = SuperviseCopy.refusal(.transport("offline"), fallback: "fallback")
        XCTAssertEqual(offline, SessionCopy.appearOfflineCheckConnection)
        let french = L10nRuntime.withLocale(.frCA) { SuperviseCopy.refusal(ended, fallback: "fallback") }
        XCTAssertEqual(french, "Cet appel est terminé.")
    }

    /// Each problem's sentence: a join that failed or dropped is the connect sentence, a coach
    /// leg that failed is Sean's microphone sentence.
    func testEachProblemHasItsSentence() {
        XCTAssertNil(SuperviseCopy.problem(nil))
        let connect = "Could not connect you to the call. Try again."
        XCTAssertEqual(SuperviseCopy.problem(.listenFailed(message: "x")), connect)
        XCTAssertEqual(SuperviseCopy.problem(.listenDropped(reason: nil)), SuperviseCopy.monitorConnectFailed)
        XCTAssertEqual(
            SuperviseCopy.problem(.listenRefused(.http(status: 500, message: nil, code: nil))),
            SuperviseCopy.monitorConnectFailed
        )
        XCTAssertEqual(
            SuperviseCopy.problem(.takeoverRefused(.http(status: 500, message: nil, code: nil))),
            "The call could not be taken over. Try again."
        )
        XCTAssertEqual(
            SuperviseCopy.problem(.takeoverJoinFailed(message: nil)),
            "Could not join the call with your microphone. Check that a microphone is connected and that "
                + "District AI may use it, then try again."
        )
        XCTAssertEqual(SuperviseCopy.problem(.takeoverDropped(reason: nil)), SuperviseCopy.takeOverJoinFailed)
    }

    /// Sean's approved French, word for word (2026-11-05).
    func testTheApprovedFrenchIsWordForWord() {
        L10nRuntime.withLocale(.frCA) {
            XCTAssertEqual(SuperviseCopy.joining, "Connexion à l'appel en cours.")
            XCTAssertEqual(SuperviseCopy.takingOver, "Prise de l'appel en cours.")
            XCTAssertEqual(SuperviseCopy.callEnded, "L'appel est terminé.")
            XCTAssertEqual(SuperviseCopy.whisperTooLong(2000), "La consigne doit compter au plus 2000 caractères.")
            XCTAssertEqual(SuperviseCopy.whisperNotApplied, "Votre réceptionniste n'a pas pu utiliser votre consigne.")
            XCTAssertEqual(SuperviseCopy.receptionistNotOnCall, "Votre réceptionniste ne participe pas à cet appel")
        }
    }
}
