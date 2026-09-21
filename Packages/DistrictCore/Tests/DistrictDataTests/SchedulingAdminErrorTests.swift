@testable import DistrictData
import DistrictModel
import Foundation
import XCTest

final class SchedulingAdminErrorTests: XCTestCase {
    /// ⛔ THE FIVE-CODE COLLAPSE IS ASSERTED FOR EVERY ARM, because it is the one
    /// thing this client and the browser have to agree on — a person shown two
    /// different explanations of one refusal depending on which device they picked
    /// it up on reports a bug against whichever they saw second.
    func testEveryErrorCollapsesOntoTheRightCode() {
        let expectations: [(SchedulingAdminError, SchedulingAdminFailureCode)] = [
            (.failure(.slotTaken), .slotTaken),
            (.failure(.unavailable), .unavailable),
            (.failure(.unknown), .unknown),
            (.invalidParams(["slug"]), .unknown),
            (.forbidden, .forbidden),
            (.notReady, .notReady),
            (.unavailable, .unavailable),
            (.unknown, .unknown),
            (.transport("offline"), .unavailable),
            (.decoding("shape"), .unknown),
        ]
        for (error, expected) in expectations {
            XCTAssertEqual(error.uiCode, expected, "\(error)")
        }
    }

    /// ⚠️ THE CODES ARE A CLOSED FIVE. A sixth would be a sentence the App has no
    /// copy for.
    func testTheCodeVocabularyIsTheKnownFive() {
        XCTAssertEqual(
            SchedulingAdminFailureCode.allCases.map(\.rawValue),
            ["unavailable", "slotTaken", "forbidden", "notReady", "unknown"]
        )
    }

    /// ⛔ `ApiError.decoding` CANNOT ARRIVE THROUGH `sendUnmapped` TODAY AND THE
    /// ARM IS STILL SPELLED OUT, WHICH IS WHY IT IS TESTED HERE DIRECTLY RATHER
    /// THAN THROUGH `perform`. `sendUnmapped` skips the status mapping entirely, so
    /// the only failures it can produce are an unbuildable path, a missing
    /// credential and a dead socket — a transport reason or a synthetic 401.
    /// Collapsing the third case into one of the others, or reaching for a
    /// `default`, would mean a future change to `ApiClient` could route a decode
    /// failure here and have it silently reported as something it is not; the
    /// exhaustive switch makes that a compile error instead.
    func testTheUnansweredMappingCoversEveryApiErrorCase() {
        XCTAssertEqual(
            SchedulingAdminRepository.error(forUnanswered: .http(status: 403, message: nil)),
            .forbidden
        )
        XCTAssertEqual(
            SchedulingAdminRepository.error(forUnanswered: .transport("offline")),
            .transport("offline")
        )
        XCTAssertEqual(
            SchedulingAdminRepository.error(forUnanswered: .decoding("shape")),
            .decoding("shape")
        )
    }
}
