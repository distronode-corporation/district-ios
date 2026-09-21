@testable import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The subject an email reply goes out with.
///
/// ⛔ WHAT THIS IS DEFENDING: `messages/send` reads
/// `(typeof subject === "string" && subject.trim()) || "Message from District"`, and
/// this client sent nothing — so every email reply the product had ever sent was
/// titled "Message from District" and threaded with none of them in the customer's
/// mail client. The server accepts that send happily, so nothing downstream can catch
/// it and these are the tests that hold the line.
///
/// ⚠️ THE EVENTS ARE BUILT THROUGH ``ThreadPageReader``, not by hand. That is the only
/// producer of a ``ThreadEvent`` in the app, so a document shape the reader stops
/// accepting fails here too rather than leaving these passing against a value the
/// client can no longer construct.
final class ReplySubjectTests: XCTestCase {
    /// ⛔ NEWEST FIRST. ``ThreadPage/events`` is OLDEST-first, so the last
    /// subject-bearing row is the conversation the operator is looking at; taking the
    /// first would answer a thread's opening email months after it was superseded.
    func testTheNewestSubjectIsTheOneAnswered() throws {
        let events = try Self.events([
            Self.emailRow(id: "m_1", at: "2026-08-19T09:00:00.000Z", subject: "Roof survey"),
            Self.emailRow(id: "m_2", at: "2026-08-19T10:00:00.000Z", subject: "Quote for the survey"),
        ])

        XCTAssertEqual(ReplySubject.reply(to: events), "Re: Quote for the survey")
    }

    /// ⚠️ AN ALREADY-PREFIXED SUBJECT IS RETURNED UNCHANGED, so a long exchange does
    /// not accumulate `Re: Re: Re:` down the customer's inbox.
    func testAnAlreadyPrefixedSubjectIsNotPrefixedAgain() throws {
        let events = try Self.events([
            Self.emailRow(id: "m_1", at: "2026-08-19T09:00:00.000Z", subject: "Re: Roof survey"),
        ])

        XCTAssertEqual(ReplySubject.reply(to: events), "Re: Roof survey")
    }

    /// ⚠️ CASE-INSENSITIVELY, because the prefix arrives from whatever wrote it — a
    /// customer's mail client, not this app.
    func testThePrefixTestIgnoresCase() throws {
        let events = try Self.events([
            Self.emailRow(id: "m_1", at: "2026-08-19T09:00:00.000Z", subject: "RE: Roof survey"),
        ])

        XCTAssertEqual(ReplySubject.reply(to: events), "RE: Roof survey")
    }

    /// ⚠️ A BLANK SUBJECT IS NOT A SUBJECT, and `Re: ` alone is worse than nothing.
    /// The walk carries on to an older row that has one.
    func testABlankSubjectIsSkippedForAnOlderRealOne() throws {
        let events = try Self.events([
            Self.emailRow(id: "m_1", at: "2026-08-19T09:00:00.000Z", subject: "Roof survey"),
            Self.emailRow(id: "m_2", at: "2026-08-19T10:00:00.000Z", subject: "   "),
        ])

        XCTAssertEqual(ReplySubject.reply(to: events), "Re: Roof survey")
    }

    /// ⛔ AND NOTHING IS INVENTED. A thread of SMS and calls has no subject to answer,
    /// and a manufactured line would be this client asserting a topic nobody chose —
    /// the smaller version of the bug it is here to fix. nil means the operator writes
    /// it, and the composer refuses to send until they do.
    func testAThreadThatHasNeverCarriedASubjectDerivesNone() throws {
        let events = try Self.events([Self.smsRow, Self.callRow])

        XCTAssertNil(ReplySubject.reply(to: events))
    }

    /// ⚠️ AN EMPTY THREAD IS THE SAME ANSWER, and it is reachable: a brand new
    /// conversation with a contact who has written nothing yet.
    func testAnEmptyThreadDerivesNoSubject() {
        XCTAssertNil(ReplySubject.reply(to: []))
    }

    /// ⚠️ THE SUBJECT IS TRIMMED BEFORE IT IS PREFIXED, so a stored value with leading
    /// whitespace does not produce `Re:  Roof survey`.
    func testTheAnsweredSubjectIsTrimmed() throws {
        let events = try Self.events([
            Self.emailRow(id: "m_1", at: "2026-08-19T09:00:00.000Z", subject: "  Roof survey  "),
        ])

        XCTAssertEqual(ReplySubject.reply(to: events), "Re: Roof survey")
    }

    // MARK: - Helpers

    /// One email row, which is the only kind that carries a subject.
    private static func emailRow(id: String, at timestamp: String, subject: String) -> String {
        #"""
        {"id":"\#(id)","type":"email","direction":"inbound","timestamp":"\#(timestamp)",
         "body":"Any update?","status":"received","subject":"\#(subject)"}
        """#
    }

    private static let smsRow = #"""
    {"id":"m_sms","type":"sms","direction":"inbound","timestamp":"2026-08-19T09:41:00.000Z",
     "body":"On my way.","status":"received"}
    """#

    private static let callRow = #"""
    {"id":"call_1","type":"call","direction":"inbound","timestamp":"2026-08-19T09:40:00.000Z",
     "body":"Booked a survey.","status":"completed","duration":65,"summary":"Booked a survey.",
     "hasTranscript":false}
    """#

    /// The rows through the real reader, so these events are the ones the app holds.
    private static func events(_ rows: [String]) throws -> [ThreadEvent] {
        let json = #"{"success":true,"timeline":[\#(rows.joined(separator: ","))]}"#
        let document = try XCTUnwrap(JSONWire.decode(Data(json.utf8)))
        return try XCTUnwrap(ThreadPageReader.read(document).successOnly).events
    }
}
