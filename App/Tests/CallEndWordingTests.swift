@testable import DistrictAI
import DistrictCall
import DistrictL10n
import XCTest

/// The end screen words every end from the catalog, never from the SDK (3.0.1).
///
/// ⛔ `.remoteEnded` and `.failed` carry LiveKit's English error description: "Room deleted"
/// when the caller hung up and the room went, "Timed out" for a join that never finished.
/// That text is logged by `LiveKitCallEngine`; the screen says the catalog's sentence, in
/// English and in French.
final class CallEndWordingTests: XCTestCase {
    private func french<T>(_ body: () -> T) -> T {
        L10nRuntime.withLocale(.frCA, body)
    }

    func testARoomDeletedEndReadsAsTheCatalogsWordInBothLanguages() {
        let reason = CallEndReason.remoteEnded(reason: "Room deleted")

        XCTAssertEqual(InCallCopy.word(for: reason, endedByOperator: false), "the other end ended it")
        XCTAssertEqual(french { InCallCopy.word(for: reason, endedByOperator: false) }, "l'autre personne y a mis fin")
        XCTAssertEqual(
            InCallCopy.endedSentence(reason: reason, endedByOperator: false, seconds: 62, answered: true),
            "Call ended · the other end ended it · 1:02"
        )
        XCTAssertEqual(
            french { InCallCopy.endedSentence(reason: reason, endedByOperator: false, seconds: 62, answered: true) },
            "Appel terminé · l'autre personne y a mis fin · 1:02"
        )
    }

    func testAnSDKFailureMessageReadsAsTheCatalogsWordInBothLanguages() {
        let reason = CallEndReason.failed(message: "Timed out")

        XCTAssertEqual(InCallCopy.word(for: reason, endedByOperator: false), "the call could not be connected")
        XCTAssertEqual(
            french { InCallCopy.word(for: reason, endedByOperator: false) },
            "l'appel n'a pas pu être établi"
        )
        XCTAssertEqual(
            InCallCopy.endedSentence(reason: reason, endedByOperator: false, seconds: 0, answered: false),
            "Call ended · the call could not be connected"
        )
        XCTAssertEqual(
            french { InCallCopy.endedSentence(reason: reason, endedByOperator: false, seconds: 0, answered: false) },
            "Appel terminé · l'appel n'a pas pu être établi"
        )
    }
}
