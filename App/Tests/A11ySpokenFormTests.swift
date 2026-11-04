@testable import DistrictAI
import DistrictModel
import XCTest

/// The strings that exist only to be SAID.
///
/// ⛔ THESE ARE NOT COVERED BY ANY SCREEN TEST, AND THAT IS WHY THEY BREAK QUIETLY.
/// A wrong `accessibilityLabel` renders identically to a right one: nothing on
/// screen changes, no snapshot moves, and the only way to notice is to turn
/// VoiceOver on and listen. Pinning the pure functions behind them is the one gate
/// available above the package boundary.
/// ⚠️ `@MainActor` FOR `DialerModel`'S SAKE. Its copy helpers are static but the type
/// is main-actor isolated, so a synchronous nonisolated call to one does not compile
/// under Swift 6 — the same shape `IncomingCallSentenceTests` records.
@MainActor
final class A11ySpokenFormTests: XCTestCase {
    // MARK: - Chart bar values

    /// ⛔ THE SINGULAR IS THE POINT. VoiceOver reads a bar's value once per bar as a
    /// person swipes along the chart, so "1 calls" is not a typo seen once — it is
    /// heard on every bucket with a single call, and it is what makes a screen reader
    /// sound broken rather than merely terse.
    func testOneCallIsSingular() {
        XCTAssertEqual(AnalyticsFormat.callCount(1), "1 call")
    }

    func testEveryOtherCountIsPlural() {
        XCTAssertEqual(AnalyticsFormat.callCount(0), "0 calls")
        XCTAssertEqual(AnalyticsFormat.callCount(2), "2 calls")
        XCTAssertEqual(AnalyticsFormat.callCount(97), "97 calls")
    }

    /// ⚠️ A ZERO BUCKET IS A REAL AND COMMON VALUE, not an absent one. The analytics
    /// route seeds one point per bucket and fills from the query, so a quiet
    /// workspace produces a full series of zeros — see the ⚠️ on
    /// `AnalyticsTrendCard.isQuietWindow`. It must be sayable.
    func testAQuietBucketStillSaysSomething() {
        XCTAssertFalse(AnalyticsFormat.callCount(0).isEmpty)
    }

    // MARK: - The dialer's destination hint

    /// ⛔ THE LINE THAT WOULD HAVE CAUGHT THE CALL TO THE WRONG COUNTRY. It is the
    /// Call button's accessibility hint, which is the last thing VoiceOver says
    /// before a person presses a control that spends money.
    func testANamedCountryIsSaidWithTheWholeNumber() {
        XCTAssertEqual(
            DialerModel.destinationLine(DialPlan.read("+41 65 550 12 34", country: nil)),
            "Rings Switzerland · +41 65 550 12 34"
        )
    }

    /// ⚠️ AN UNRECOGNISED CODE IS STILL DIALABLE, so the sentence warns rather than
    /// refuses — the app knows that it does not know, which is a different fact from
    /// the number being wrong.
    func testAnUnrecognisedCodeWarnsWithoutRefusing() {
        let reading = DialPlan.read("+999 1234 5678", country: nil)
        XCTAssertNotNil(reading.e164)
        XCTAssertEqual(
            DialerModel.destinationLine(reading),
            "Unrecognised country code. Check the number before calling."
        )
    }

    /// ⛔ nil, NOT AN EMPTY SENTENCE. With no complete number there is nothing to send, and
    /// `DialerView` turns this into an absent hint rather than a pause before the label.
    func testAnIncompleteNumberSaysNothingAtAll() {
        XCTAssertNil(DialerModel.destinationLine(DialPlan.read("", country: nil)))
    }

    /// ⚠️ THE FLAG BUTTON IS READ AS A COUNTRY AND A CODE, never as the emoji's two letters.
    func testTheCountryButtonIsSaidAsANameAndACode() {
        XCTAssertEqual(DialerModel.countryButton("Canada", "1"), "Canada, calling code +1")
    }
}
