import CallKit
@testable import DistrictAI
@testable import DistrictCall
import XCTest

/// ``IncomingCallCopy/endedReason(for:)`` decides what the SYSTEM is told, which
/// is a different question from what the screen says.
///
/// ⚠️ IT IS NOT THE MIRROR OF ``InCallCopy/word(for:endedByOperator:)``, THOUGH IT
/// READS LIKE ONE. This maps a phase to a `CXCallEndedReason`, and that value's
/// only job is which entry the call gets in the system's Recents list. The
/// inbound screen's WORDING goes through
/// ``IncomingCallCopy/sentence(for:endedByOperator:)``, which
/// `IncomingCallSentenceTests` below covers — that is the real mirror.
final class IncomingCallCopyTests: XCTestCase {
    /// ⛔ `unanswered` IS WHAT PUTS A MISSED CALL IN RECENTS, which is where a
    /// person looks for one. It is right for a ring nobody reached in time and
    /// wrong for a caller who hung up: they were answered by nobody, but the call
    /// did happen.
    func testRingTimedOutIsReportedAsUnanswered() {
        XCTAssertEqual(IncomingCallCopy.endedReason(for: .ended(.ringTimedOut)), .unanswered)
    }

    func testFarEndEndingsAreReportedAsRemoteEnded() {
        for reason: CallEndReason in [.callerCancelled, .remoteHungUp, .remoteEnded(reason: nil)] {
            XCTAssertEqual(
                IncomingCallCopy.endedReason(for: .ended(reason)), .remoteEnded,
                "\(reason) is the far end leaving and belongs in Recents as such"
            )
        }
    }

    func testFailuresAreReportedAsFailed() {
        for reason: CallEndReason in [.failed(message: nil), .answerRefused(message: nil)] {
            XCTAssertEqual(IncomingCallCopy.endedReason(for: .ended(reason)), .failed)
        }
    }

    /// ⚠️ THE TWO LOCAL ENDINGS ARE DOCUMENTED AS UNREACHABLE AND ANSWERED ANYWAY.
    /// Both went through a `CXEndCallAction` before the reducer produced them, so
    /// the OS already knows. Pinned so the deliberate answer cannot decay into a
    /// silent `default`.
    func testLocalEndingsStillAnswerRatherThanFallThrough() {
        XCTAssertEqual(IncomingCallCopy.endedReason(for: .ended(.declined)), .remoteEnded)
        XCTAssertEqual(IncomingCallCopy.endedReason(for: .ended(.hungUpLocally)), .remoteEnded)
    }

    /// ⚠️ A PHASE THAT IS NOT `ended` IS NOT A CALL THAT ENDED CLEANLY.
    func testNonEndedPhasesReportFailed() {
        for phase: IncomingCallPhase in [.idle, .ringing] {
            XCTAssertEqual(IncomingCallCopy.endedReason(for: phase), .failed)
        }
    }
}

/// The inbound half of the ended-call wording, pinned.
///
/// ⛔ THE DIALLER'S TESTS DO NOT COVER THIS SCREEN: the two machines are separate
/// models. If `sentence(for:)` reached the unattributed one-argument `word(for:)`,
/// an incoming call ending `.hungUpLocally` would render "Call ended · you hung up"
/// whether or not a person had touched the button.
@MainActor
final class IncomingCallSentenceTests: XCTestCase {
    /// ⚠️ `@testable import DistrictCall` IS WHAT MAKES THIS POSSIBLE, and it is the
    /// idiom the package's own suite already uses. ``IncomingCallState/phase`` is
    /// `public internal(set)`, so a state in a chosen phase cannot be built through
    /// the public API at all; the alternative is driving ``IncomingCallController``
    /// through a real event sequence, which would couple a COPY test to the reducer's
    /// transition table and fail for reasons that have nothing to do with wording.
    private func ended(_ reason: CallEndReason) -> IncomingCallState {
        var state = IncomingCallState()
        state.phase = .ended(reason)
        return state
    }

    /// ⛔ THE HEADLINE, AND THE EXACT STRING THAT WAS WRONG.
    func testHungUpLocallyWithoutAttributionDoesNotBlameTheOperator() {
        let sentence = IncomingCallCopy.sentence(for: ended(.hungUpLocally), endedByOperator: false)
        XCTAssertEqual(sentence, "Call ended")
        XCTAssertFalse(sentence.contains("you hung up"))
    }

    func testHungUpLocallyByTheOperatorIsStillSaid() {
        XCTAssertEqual(
            IncomingCallCopy.sentence(for: ended(.hungUpLocally), endedByOperator: true),
            "Call ended · you hung up"
        )
    }

    /// ⚠️ EVERY OTHER REASON IS INDIFFERENT TO THE FLAG, exactly as on the outbound
    /// screen: the withholding must not widen to endings the reducer CAN attribute.
    func testOtherReasonsAreUnaffectedByAttribution() {
        let cases: [(CallEndReason, String)] = [
            (.remoteHungUp, "Call ended · they hung up"),
            (.callerCancelled, "Call ended · the caller hung up"),
            (.ringTimedOut, "Call ended · nobody answered"),
            (.declined, "Call ended · declined"),
        ]
        for (reason, expected) in cases {
            for attributed in [true, false] {
                XCTAssertEqual(
                    IncomingCallCopy.sentence(for: ended(reason), endedByOperator: attributed),
                    expected,
                    "\(reason) should read the same either way"
                )
            }
        }
    }
}
