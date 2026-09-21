import DistrictModel
import XCTest

/// ``CallerIdentity`` and ``CallNarrative``: the two places this client decides that
/// a non-empty string from the server means "there is nothing here".
///
/// ⛔ EVERY LITERAL BELOW IS COPIED FROM A SERVER FILE, NOT INVENTED. The whole
/// mechanism is an exact-match set, so a test that asserted against a paraphrase
/// would pass while the app kept rendering the real string. The server line for each
/// is named in the doc comment on the set itself.
final class CallSentinelTests: XCTestCase {
    // MARK: - CallerIdentity

    /// ⛔ THE CASE THAT SHIPPED. `"Inbound SIP Caller"` is not blank and is not
    /// "Unknown", which is why a blank-only test and an Unknown-only test both passed
    /// while three screens printed it as a contact's name.
    func testTheWebhooksCallerPlaceholdersNameNobody() {
        XCTAssertNil(CallerIdentity.resolved("Inbound SIP Caller"))
        XCTAssertNil(CallerIdentity.resolved("Outbound Campaign Caller"))
        XCTAssertNil(CallerIdentity.resolved("Unknown"))
    }

    /// ⚠️ THE SET AND THE FUNCTION MUST NOT DRIFT. `placeholders` is public because
    /// it is the documented list; this asserts the resolver actually consults it
    /// rather than carrying its own copy of two of the three.
    func testEveryPublishedPlaceholderResolvesToNobody() {
        XCTAssertEqual(CallerIdentity.placeholders.count, 3)
        for placeholder in CallerIdentity.placeholders {
            XCTAssertNil(CallerIdentity.resolved(placeholder), "\(placeholder) is a placeholder, not a caller")
        }
    }

    /// ⛔ BLANK AND ABSENT STILL COUNT AS ABSENT. The rule this replaced was a blank
    /// check, and subsuming it rather than adding beside it is the point: a row whose
    /// number is whitespace is not something to call back.
    func testBlankAndMissingNameNobody() {
        XCTAssertNil(CallerIdentity.resolved(nil))
        XCTAssertNil(CallerIdentity.resolved(""))
        XCTAssertNil(CallerIdentity.resolved("   "))
    }

    /// ⛔ A REAL CALLER SURVIVES, WHICH IS THE HALF A TOO-EAGER FILTER WOULD BREAK.
    /// Both shapes reach these fields: `number` is a resolved contact NAME where one
    /// exists and the raw E.164 otherwise.
    func testARealCallerSurvives() {
        XCTAssertEqual(CallerIdentity.resolved("+14165550100"), "+14165550100")
        XCTAssertEqual(CallerIdentity.resolved("Ada Lovelace"), "Ada Lovelace")
    }

    /// ⚠️ THE MATCH IS EXACT, NOT A PREFIX OR A CONTAINS. A caller genuinely named
    /// something that merely starts with a placeholder is still a caller, and a
    /// `hasPrefix` implementation would silently erase them.
    func testTheMatchIsExactRatherThanAPrefix() {
        XCTAssertEqual(CallerIdentity.resolved("Unknown Caller Ltd"), "Unknown Caller Ltd")
        XCTAssertEqual(CallerIdentity.resolved("Inbound SIP Callers Inc"), "Inbound SIP Callers Inc")
    }

    /// ⚠️ PADDING IS TRIMMED OFF THE VALUE THAT COMES BACK, not merely looked past.
    /// Emptiness is tested after trimming, so returning the original would print a
    /// name this function had already decided was padded.
    func testTheResolvedValueComesBackTrimmed() {
        XCTAssertEqual(CallerIdentity.resolved("  +14165550100 "), "+14165550100")
    }

    /// ⛔ AND A PADDED PLACEHOLDER IS STILL A PLACEHOLDER. Matching before trimming
    /// would let one whitespace character put the sentence back on screen.
    func testAPaddedPlaceholderIsStillAPlaceholder() {
        XCTAssertNil(CallerIdentity.resolved(" Inbound SIP Caller "))
    }

    // MARK: - CallNarrative

    /// ⛔ THE MARKER THAT MADE THIS NECESSARY. Every outbound softphone call carries
    /// `"direct:softphone"` in `Call.summary` permanently, and it was rendering under
    /// a heading that says "AI summary".
    func testTheSoftphoneMarkerIsNotASummary() {
        XCTAssertEqual(CallNarrative.summary("direct:softphone"), .absent)
    }

    /// ⛔ THE SERVER'S OWN FALLBACK IS NOT A SUMMARY EITHER, and it is why a blank
    /// check on this field could never fire: the wire value is `c.summary || "No
    /// summary available."`, so the field always has text in it.
    func testTheServersFallbackSentenceIsNotASummary() {
        XCTAssertEqual(CallNarrative.summary("No summary available."), .absent)
    }

    /// ⚠️ THE LIFECYCLE SENTENCES ARE STATUS, NOT NARRATIVE. Both "active" forms are
    /// listed because the webhook only ever overwrites one of them.
    func testTheLifecycleSentencesAreNotSummaries() {
        XCTAssertEqual(CallNarrative.summary("AI Voice session active..."), .absent)
        XCTAssertEqual(CallNarrative.summary("AI Outbound Voice session active..."), .absent)
        XCTAssertEqual(CallNarrative.summary("Voice session completed."), .absent)
    }

    /// ⛔ THE EM DASH IS THE SERVER'S BYTE, U+2014, AND THE MATCH IS EXACT. Spelled
    /// with an escape in both the source and this test so that neither can be
    /// "tidied" into a hyphen without the other failing.
    func testTheNoAnswerSentenceMatchesTheServersEmDash() {
        XCTAssertEqual(CallNarrative.summary("No answer \u{2014} no conversation took place."), .absent)
    }

    /// ⛔ A FAILED SUMMARISER IS NOT AN ABSENT SUMMARY. Folding these into `.absent`
    /// would tell an operator there was nothing to say about a call that this product
    /// simply failed to read.
    func testARecordedSummariserFailureIsItsOwnAnswer() {
        XCTAssertEqual(CallNarrative.summary("Error processing audio with AI."), .failed)
        XCTAssertEqual(CallNarrative.summary("AI analysis failed to execute."), .failed)
    }

    /// ⚠️ THE TWO SETS MUST NOT OVERLAP, or the order of the checks in `summary(_:)`
    /// would silently decide which answer a caller got.
    func testThePlaceholderAndFailureSetsAreDisjoint() {
        XCTAssertEqual(CallNarrative.placeholders.count, 6)
        XCTAssertEqual(CallNarrative.failures.count, 2)
        XCTAssertTrue(CallNarrative.placeholders.isDisjoint(with: CallNarrative.failures))
    }

    /// ⚠️ THE SETS AND THE FUNCTION MUST NOT DRIFT, the same assertion made above for
    /// the caller sentinels.
    func testEveryPublishedNarrativeSentinelIsClassified() {
        for placeholder in CallNarrative.placeholders {
            XCTAssertEqual(CallNarrative.summary(placeholder), .absent, placeholder)
        }
        for failure in CallNarrative.failures {
            XCTAssertEqual(CallNarrative.summary(failure), .failed, failure)
        }
    }

    /// ⛔ A REAL SUMMARY SURVIVES, TRIMMED. This is the half that must keep working.
    func testARealSummarySurvives() {
        XCTAssertEqual(
            CallNarrative.summary("  Booked a survey for Thursday.  "),
            .text("Booked a survey for Thursday.")
        )
    }

    /// ⚠️ AN EMPTY OR BLANK VALUE IS ABSENT RATHER THAN AN EMPTY CARD. The server does
    /// not send one today, which is exactly why the branch needs a test rather than a
    /// witness.
    func testAnEmptyValueIsAbsent() {
        XCTAssertEqual(CallNarrative.summary(""), .absent)
        XCTAssertEqual(CallNarrative.summary("   "), .absent)
    }
}
