@testable import DistrictAI
import DistrictModel
import XCTest

/// Whether the call detail offers "Show transcript" (#159): a call the service says has no
/// transcript does not offer one; a call that has one, or a service that does not say, does.
final class CallTranscriptOfferTests: XCTestCase {
    private func call(hasTranscript: String?) throws -> CallSummary {
        let field = hasTranscript.map { #","hasTranscript":\#($0)"# } ?? ""
        return try JSONDecoder().decode(CallSummary.self, from: Data("""
        {"id":"call_1","type":"missed","number":"+15555550100","status":"no-answer","duration":"0s",\
        "time":"t","aiSummary":"","transcript":"","callerName":"","summary":"",\
        "createdAt":"2026-10-06T14:30:00.000Z"\(field)}
        """.utf8))
    }

    /// ⛔ THE BUG: the button was drawn for a call the service had just said had no transcript.
    func testACallWithNoTranscriptOffersNone() throws {
        XCTAssertFalse(try CallDisplay(call(hasTranscript: "false")).offersTranscript)
    }

    func testACallWithATranscriptOffersIt() throws {
        XCTAssertTrue(try CallDisplay(call(hasTranscript: "true")).offersTranscript)
    }

    /// An older service that does not send the field keeps the button, as before.
    func testAServiceThatDoesNotSayKeepsTheButton() throws {
        XCTAssertTrue(try CallDisplay(call(hasTranscript: nil)).offersTranscript)
        XCTAssertTrue(try CallDisplay(call(hasTranscript: "null")).offersTranscript)
    }
}
