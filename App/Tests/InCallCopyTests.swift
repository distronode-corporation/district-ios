@testable import DistrictAI
import DistrictCall
import XCTest

/// ⛔ THIS FILE EXISTS BECAUSE WHAT IT PINS IS REACHABLE FROM NO OTHER GATE.
/// `DialEntry.assess(_:)` lives in DistrictCore (district-core-swift) and
/// `DialNumberTests` covers it on the Linux runner there. ``InCallCopy/word(for:endedByOperator:)`` lives
/// ABOVE the package boundary, in the App target: without this bundle, deleting the
/// `endedByOperator ?` would leave every gate green and put "you hung up" in front
/// of an operator who had not hung up.
final class InCallCopyTests: XCTestCase {
    // MARK: - word(for:endedByOperator:)

    /// ⛔ THE HEADLINE. `hungUpLocally` is the one reason two causes share: the
    /// in-app button AND a `CXEndCallAction` the OS performed both produce it, so
    /// the reason alone cannot name a person. Unattributed, the word is withheld.
    func testHungUpLocallyWithoutOperatorAttributionSaysNothing() {
        XCTAssertNil(InCallCopy.word(for: .hungUpLocally, endedByOperator: false))
    }

    func testHungUpLocallyByTheOperatorIsWorded() {
        XCTAssertEqual(InCallCopy.word(for: .hungUpLocally, endedByOperator: true), "you hung up")
    }

    /// ⚠️ EVERY OTHER REASON IS INDIFFERENT TO THE FLAG, and that is the property
    /// worth pinning: a future change that widened the withholding to reasons the
    /// reducer CAN attribute would make the screen say less than it knows.
    func testEveryOtherReasonIsUnaffectedByAttribution() {
        let unaffected: [(CallEndReason, String)] = [
            (.remoteHungUp, "they hung up"),
            (.remoteEnded(reason: nil), "the other end ended it"),
            (.remoteEnded(reason: "carrier released"), "carrier released"),
            (.failed(message: nil), "the call could not be connected"),
            (.failed(message: "no answer from the trunk"), "no answer from the trunk"),
            (.declined, "declined"),
            (.ringTimedOut, "nobody answered"),
            (.callerCancelled, "the caller hung up"),
            (.answerRefused(message: nil), "the answer was refused"),
            (.answerRefused(message: "already on a call"), "already on a call"),
        ]
        for (reason, expected) in unaffected {
            XCTAssertEqual(
                InCallCopy.word(for: reason, endedByOperator: true), expected,
                "\(reason) should word the same when the operator ended it"
            )
            XCTAssertEqual(
                InCallCopy.word(for: reason, endedByOperator: false), expected,
                "\(reason) should word the same when the operator did not end it"
            )
        }
    }

    // MARK: - endedSentence(word:seconds:answered:)

    /// ⛔ THE USER-VISIBLE CONSEQUENCE OF A nil WORD. The sentence must shorten,
    /// not dangle on its separator — "Call ended ·" would read as a truncated
    /// string rather than as an honest one.
    func testNilWordShortensTheSentenceRatherThanDangling() {
        XCTAssertEqual(
            InCallCopy.endedSentence(word: nil, seconds: 0, answered: false), "Call ended"
        )
        XCTAssertEqual(
            InCallCopy.endedSentence(word: nil, seconds: 62, answered: true), "Call ended · 1:02"
        )
    }

    func testWordAndDurationCompose() {
        XCTAssertEqual(
            InCallCopy.endedSentence(word: "they hung up", seconds: 62, answered: true),
            "Call ended · they hung up · 1:02"
        )
    }

    /// ⚠️ AN UNANSWERED CALL CARRIES NO DURATION. "Lasted 0:00" says the callee
    /// picked up and said nothing, which is the opposite of what happened.
    func testUnansweredCallOmitsTheDuration() {
        XCTAssertEqual(
            InCallCopy.endedSentence(word: "nobody answered", seconds: 0, answered: false),
            "Call ended · nobody answered"
        )
    }

    // MARK: - duration(_:)

    /// ⚠️ PAST AN HOUR IT KEEPS COUNTING RATHER THAN WRAPPING, which the mm:ss
    /// format makes easy to regress into a 12:14 that means 72 minutes.
    func testDurationDoesNotWrapAtAnHour() {
        XCTAssertEqual(InCallCopy.duration(4334), "72:14")
    }

    func testDurationPadsSecondsAndFloorsNegatives() {
        XCTAssertEqual(InCallCopy.duration(9), "0:09")
        XCTAssertEqual(InCallCopy.duration(60), "1:00")
        XCTAssertEqual(InCallCopy.duration(-5), "0:00")
    }
}
