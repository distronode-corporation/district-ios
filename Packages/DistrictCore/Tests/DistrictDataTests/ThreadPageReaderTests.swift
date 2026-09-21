@testable import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The timeline reader: ``TimelineResponse`` first, the hand-written
/// `JSONValue` → ``ThreadPage`` mapping second.
///
/// ⛔ THE FALLBACK IS THE HALF WITH NO CONTRACT GATE BEHIND IT, WHICH IS WHY MOST
/// OF THIS FILE STILL POINTS AT IT. Both timeline fixtures are gated now, so the
/// strict decode/re-encode walk pins what the TYPED path reads; nothing pins the
/// shape-guarded walk, because by definition it runs on documents the fixtures do
/// not describe. What covers it is this file: both wire shapes, every degrade,
/// and the count of what could not be read.
///
/// ⚠️ AND ONE CLAIM THAT SPANS BOTH: for any document that decodes typed, the two
/// paths must produce the SAME ``ThreadPage``. Without that, a fleet where some
/// origins lag the fixture corpus would render the same thread two different ways
/// depending on which origin answered, and the difference would show up as a
/// customer's message appearing or not.
final class ThreadPageReaderTests: XCTestCase {
    // MARK: - The two shapes

    /// ⛔ THE DEPLOYED ROUTE HAS NO `pageInfo` AND THEREFORE NO PAGING. A client
    /// that offered "load older" anyway would send a cursor the server discards,
    /// get **the same window back**, and either append every row twice or spin
    /// forever on a button that never runs out.
    func testTheDeployedShapeOffersNoCursorAndNoMore() throws {
        let page = try read(#"{"success":true,"timeline":[\#(Self.smsRow)]}"#)

        XCTAssertEqual(page.events.map(\.id), ["m_1"])
        XCTAssertNil(page.cursor)
        XCTAssertFalse(page.hasMore)
        XCTAssertFalse(page.isIncomplete)
    }

    /// ⚠️ THE CURSOR VALUES ARE THE SERVER'S OWN, echoed back from `pageInfo`.
    /// Never a timestamp this client formatted: the server compares it against what
    /// it emitted.
    func testThePagedShapeCarriesTheCursorAndTheMoreFlag() throws {
        let info = #""pageInfo":{"hasMore":true,"oldest":"2026-08-19T09:00:00.000Z","oldestId":"m_0"}"#
        let page = try read(#"{"success":true,"timeline":[\#(Self.smsRow)],\#(info)}"#)

        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.cursor, ThreadCursor(before: "2026-08-19T09:00:00.000Z", beforeId: "m_0"))
    }

    /// ⛔ BOTH HALVES OR NOTHING. `beforeId` without `before` is a 400 from the
    /// route, and both `pageInfo` fields are nullable — they are null together on an
    /// empty page — so a half-populated block must produce no cursor rather than
    /// half of one.
    func testAHalfPopulatedPageInfoProducesNoCursorAtAll() throws {
        let onlyTimestamp = #""pageInfo":{"hasMore":true,"oldest":"2026-08-19T09:00:00.000Z","oldestId":null}"#
        let onlyId = #""pageInfo":{"hasMore":true,"oldest":null,"oldestId":"m_0"}"#

        let first = try read(#"{"success":true,"timeline":[],\#(onlyTimestamp)}"#)
        let second = try read(#"{"success":true,"timeline":[],\#(onlyId)}"#)

        XCTAssertNil(first.cursor)
        XCTAssertNil(second.cursor)
        // ⚠️ `hasMore` still travels: it is a separate claim from "here is where to
        // resume", and the route can honestly say there is more without offering a
        // usable cursor on an empty window.
        XCTAssertTrue(first.hasMore)
    }

    /// ⛔ A MISSING `timeline` KEY IS A MALFORMED RESPONSE, NOT AN EMPTY THREAD. The
    /// route builds the key unconditionally on its success path, so absence means
    /// the body is not the one this route sends — and rendering it as "no messages
    /// yet" shows an empty conversation for a customer who has one.
    func testAMissingTimelineArrayIsAMalformedResponseNotAnEmptyThread() throws {
        let document = try XCTUnwrap(JSONWire.decode(Data(#"{"success":true}"#.utf8)))

        let result = ThreadPageReader.read(document)

        XCTAssertEqual(result.failureOnly, .decoding("TimelineResponse success response carried no timeline array"))
    }

    func testAnEmptyThreadIsAnEmptyPageRatherThanAFailure() throws {
        let page = try read(#"{"success":true,"timeline":[]}"#)

        XCTAssertTrue(page.events.isEmpty)
        XCTAssertFalse(page.isIncomplete)
    }

    // MARK: - Per-row reading

    /// ⛔ COUNTED, NOT SWALLOWED, AND NOT FATAL EITHER. A customer with a hundred
    /// messages must not lose all of them to one unreadable row — but a silent drop
    /// is a thread quietly missing somebody's reply, so the count travels with the
    /// page and the UI says the history is incomplete.
    ///
    /// ⚠️ id AND timestamp ARE THE ONLY TWO THAT REJECT: a row with no id cannot be
    /// a list key and a row with no timestamp cannot be ordered, and inventing
    /// either would put a message at the wrong point in someone's conversation.
    func testARowWithNoIdOrNoTimestampIsCountedRatherThanSwallowed() throws {
        let noID = #"{"timestamp":"2026-08-19T09:41:00.000Z"}"#
        let blankID = #"{"id":"","timestamp":"2026-08-19T09:41:00.000Z"}"#
        let noTimestamp = #"{"id":"m_2"}"#
        let blankTimestamp = #"{"id":"m_3","timestamp":""}"#
        let rows = [Self.smsRow, noID, blankID, noTimestamp, blankTimestamp].joined(separator: ",")

        let page = try read(#"{"success":true,"timeline":[\#(rows)]}"#)

        XCTAssertEqual(page.events.map(\.id), ["m_1"])
        XCTAssertEqual(page.droppedEventCount, 4)
        XCTAssertTrue(page.isIncomplete)
    }

    /// ⚠️ EVERY OTHER FIELD DEGRADES RATHER THAN REJECTS. An unlabelled message is
    /// readable; an absent one is not.
    func testEveryFieldOtherThanIdAndTimestampDegradesToADefault() throws {
        let page = try read(#"{"success":true,"timeline":[{"id":"m_1","timestamp":"2026-08-19T09:41:00.000Z"}]}"#)
        let event = try XCTUnwrap(page.events.first)

        XCTAssertEqual(event.type, ThreadEventKind.sms)
        XCTAssertEqual(event.direction, ThreadEventDirection.inbound)
        XCTAssertEqual(event.body, "")
        XCTAssertEqual(event.status, "")
        XCTAssertNil(event.subject)
        XCTAssertEqual(event.mediaUrls, [])
        XCTAssertNil(event.durationSeconds)
        XCTAssertNil(event.summary)
        XCTAssertFalse(event.hasTranscript)
    }

    /// ⚠️ `compactMap`, SO A NON-STRING ELEMENT IS SKIPPED rather than taking out
    /// the whole attachment list. The column is `Json?` and nothing in the database
    /// enforces the shape the route filters to on the way out.
    func testANonStringAttachmentIsSkippedRatherThanLosingTheList() throws {
        let row = #"""
        {"id":"m_1","timestamp":"2026-08-19T09:41:00.000Z",
         "mediaUrls":["https://www.distronode.com/api/media/a",7,null,"https://www.distronode.com/api/media/b"]}
        """#
        let page = try read(#"{"success":true,"timeline":[\#(row)]}"#)

        let urls = try XCTUnwrap(page.events.first).mediaUrls
        XCTAssertEqual(urls, ["https://www.distronode.com/api/media/a", "https://www.distronode.com/api/media/b"])
    }

    /// ⛔ THE TRANSCRIPT ITSELF IS NOT IN THIS PAYLOAD, DELIBERATELY. Transcripts
    /// would dominate the response on every thread open; the flag exists
    /// so the UI can offer the control and fetch the text only when it is tapped.
    func testACallRowCarriesItsDurationSummaryAndTranscriptFlag() throws {
        let page = try read(#"{"success":true,"timeline":[\#(Self.callRow)]}"#)
        let event = try XCTUnwrap(page.events.first)

        XCTAssertTrue(event.isCall)
        XCTAssertEqual(event.durationSeconds, 65)
        XCTAssertEqual(event.summary, "Booked a survey.")
        XCTAssertTrue(event.hasTranscript)
    }

    /// ⛔ A CALL ROW'S `direction` IS AN OUTCOME, NOT A DIRECTION, AND THE SERVER
    /// SAYS SO IN ITS OWN COMMENT: the timeline mapper ignores `Call.direction`
    /// entirely and labels every non-failed call `inbound`, reserving `missed` for
    /// failed/no-answer. So an OUTBOUND call appears here as `inbound`, and
    /// ``ThreadEvent/isOutbound`` is false for it. Do not build a "you called them"
    /// caption from this field.
    func testACallsDirectionIsAnOutcomeSoIsOutboundIsFalseForIt() throws {
        let outboundSms = #"""
        {"id":"m_9","type":"sms","direction":"outbound","timestamp":"2026-08-19T09:42:00.000Z","body":"On our way."}
        """#
        let page = try read(#"{"success":true,"timeline":[\#(Self.callRow),\#(outboundSms)]}"#)

        let call = try XCTUnwrap(page.events.first)
        let reply = try XCTUnwrap(page.events.last)
        XCTAssertFalse(call.isOutbound, "a call row is labelled inbound whatever the call's real direction")
        XCTAssertTrue(reply.isOutbound)
        XCTAssertFalse(reply.isCall)
    }

    /// ⚠️ RAW STRINGS, LIKE EVERY DTO IN `DistrictModel`. Neither column is a
    /// database enum, and decoding into a Swift enum would fail closed on a value
    /// the server adds later — taking out the whole thread rather than one label.
    /// ⛔ `missed` is call-only.
    func testTheVocabulariesAreTheServersOwnStrings() {
        XCTAssertEqual(ThreadEventKind.sms, "sms")
        XCTAssertEqual(ThreadEventKind.email, "email")
        XCTAssertEqual(ThreadEventKind.whatsapp, "whatsapp")
        XCTAssertEqual(ThreadEventKind.call, "call")
        XCTAssertEqual(ThreadEventDirection.inbound, "inbound")
        XCTAssertEqual(ThreadEventDirection.outbound, "outbound")
        XCTAssertEqual(ThreadEventDirection.missed, "missed")
    }

    // MARK: - The typed path, and its agreement with the fallback

    /// ⛔ THE TWO PATHS MUST AGREE VALUE FOR VALUE ON THE FIELD UNION, and this
    /// document is `district-timeline.json`'s: a missed call, an answered call
    /// with a duration, a summary and a transcript flag, an outbound SMS, an MMS
    /// carrying `mediaUrls`, and an email carrying `subject`. Those are the six
    /// keys that are OPTIONAL on the DTO and defaulted by the fallback, i.e.
    /// exactly the places the two mappings could drift apart.
    func testTheTypedPathAndTheFallbackProduceTheSamePageForTheFirstPageShape() throws {
        let both = try readBothWays(Self.firstPageDocument)

        XCTAssertEqual(both.typed, both.fallback)
        XCTAssertEqual(both.typed.events.count, 5)
        XCTAssertEqual(both.typed.droppedEventCount, 0)
    }

    /// The older window. ⚠️ This is the only shape where `hasMore` is TRUE, so it
    /// is the only proof the "there is another window" branch survives both
    /// mappings rather than just decoding.
    func testTheTypedPathAndTheFallbackProduceTheSamePageForThePagedShape() throws {
        let both = try readBothWays(Self.olderPageDocument)

        XCTAssertEqual(both.typed, both.fallback)
        XCTAssertTrue(both.typed.hasMore)
    }

    /// ⚠️ THE CURSOR IS THE SERVER'S OWN PAIR, ECHOED BACK. These are
    /// `district-timeline.json`'s `pageInfo.oldest` and `pageInfo.oldestId`
    /// verbatim, and they must arrive at ``ThreadCursor`` unparsed and
    /// unreformatted: the server compares them against what it emitted.
    func testTheFirstPageCursorIsTheServersOwnOldestPair() throws {
        let page = try read(Self.firstPageDocument)

        XCTAssertEqual(
            page.cursor,
            ThreadCursor(before: "2026-08-15T13:10:00.000Z", beforeId: "call_contract_missed")
        )
    }

    /// ⛔ AN EMPTY PAGE OFFERS NOTHING, AND BOTH HALVES OF THAT MATTER. `hasMore`
    /// false stops the UI offering "load older"; a nil cursor is what stops a
    /// caller that ignores the flag from sending `beforeId` without `before`,
    /// which is a 400 rather than a smaller page.
    func testAnEmptyPageHasNoMoreAndNoCursor() throws {
        let info = #""pageInfo":{"hasMore":false,"oldest":null,"oldestId":null}"#
        let page = try read(#"{"success":true,"timeline":[],\#(info)}"#)

        XCTAssertTrue(page.events.isEmpty)
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.cursor)
    }

    /// ⛔ THE FALLBACK IS NOT DEAD CODE, AND THIS IS THE TEST THAT SAYS SO. A
    /// pre-`pageInfo` document decodes typed perfectly well (``pageInfo`` is
    /// Optional), so ``ThreadPageReader/read(_:)`` never reaches the fallback for
    /// it — which means nothing about the fallback's handling of the old shape is
    /// proven by reading it through the front door. Driven directly here instead.
    func testTheFallbackStillHandlesAPreviousGenerationDocumentOnItsOwn() throws {
        let document = try XCTUnwrap(JSONWire.decode(Data(#"{"success":true,"timeline":[\#(Self.smsRow)]}"#.utf8)))

        let page = try XCTUnwrap(ThreadPageReader.readShapeGuarded(document).successOnly)

        XCTAssertEqual(page.events.map(\.id), ["m_1"])
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.cursor)
    }

    /// ⛔ A ROW THE DTO ACCEPTS IS NOT A ROW THAT CAN BE RENDERED. `id` is
    /// non-Optional on ``TimelineEvent``, so an EMPTY id decodes typed cleanly and
    /// never reaches the fallback — the typed mapping has to drop and count it
    /// itself, or an unrenderable row would be waved through on exactly the path
    /// that runs in production.
    func testTheTypedPathDropsAndCountsARowWithAnEmptyIdOrTimestamp() throws {
        let blankID = Self.row(id: "", timestamp: "2026-08-15T13:00:00.000Z")
        let blankTimestamp = Self.row(id: "m_2", timestamp: "")
        let good = Self.row(id: "m_1", timestamp: "2026-08-15T13:01:00.000Z")
        let rows = [good, blankID, blankTimestamp].joined(separator: ",")
        let json = #"{"success":true,"timeline":[\#(rows)]}"#

        // The document really does decode typed, so `read` took the typed path.
        XCTAssertNoThrow(try JSONDecoder().decode(TimelineResponse.self, from: Data(json.utf8)))

        let page = try read(json)
        XCTAssertEqual(page.events.map(\.id), ["m_1"])
        XCTAssertEqual(page.droppedEventCount, 2)
    }

    // MARK: - Helpers

    /// `district-timeline.json`'s shape: the field union, and the cursor pair the
    /// fixture carries.
    private static let firstPageDocument = #"""
    {"success":true,"timeline":[
     {"id":"call_contract_missed","type":"call","timestamp":"2026-08-15T13:10:00.000Z","direction":"missed",
      "body":"AI call completed.","status":"no-answer","duration":0,"hasTranscript":false},
     {"id":"call_contract_answered","type":"call","timestamp":"2026-08-15T13:40:00.000Z","direction":"inbound",
      "body":"Caller booked an appointment for Thursday.","status":"completed","duration":65,
      "summary":"Caller booked an appointment for Thursday.","hasTranscript":true},
     {"id":"msg_timeline_sms_out","type":"sms","timestamp":"2026-08-15T14:05:00.000Z","direction":"outbound",
      "body":"Confirmed for Thursday at 2pm.","status":"delivered"},
     {"id":"msg_timeline_mms","type":"sms","timestamp":"2026-08-15T14:10:00.000Z","direction":"inbound",
      "body":"Here is the photo of the roof.","status":"received",
      "mediaUrls":["https://media.contract.test/roof.jpg"]},
     {"id":"msg_timeline_email","type":"email","timestamp":"2026-08-15T14:20:00.000Z","direction":"inbound",
      "body":"Could we move Thursday to Friday?","status":"received","subject":"Re: Thursday appointment"}
    ],"pageInfo":{"hasMore":false,"oldest":"2026-08-15T13:10:00.000Z","oldestId":"call_contract_missed"}}
    """#

    /// `district-timeline-page.json`'s shape, trimmed to two of its fifty rows:
    /// what the page fixture adds is `hasMore: true`, not more SMS.
    private static let olderPageDocument = #"""
    {"success":true,"timeline":[
     {"id":"msg_page_049","type":"sms","timestamp":"2026-08-15T12:11:00.000Z","direction":"inbound",
      "body":"Older message 49","status":"received"},
     {"id":"msg_page_048","type":"sms","timestamp":"2026-08-15T12:12:00.000Z","direction":"inbound",
      "body":"Older message 48","status":"received"}
    ],"pageInfo":{"hasMore":true,"oldest":"2026-08-15T12:11:00.000Z","oldestId":"msg_page_049"}}
    """#

    /// A row carrying every field the DTO requires, so the only variables are the
    /// two that decide whether it can be rendered.
    private static func row(id: String, timestamp: String) -> String {
        #"""
        {"id":"\#(id)","type":"sms","timestamp":"\#(timestamp)","direction":"inbound",
         "body":"hello","status":"received"}
        """#
    }

    /// Both mappings over one document, plus the assertion that makes the pair
    /// meaningful: the document must actually decode typed, or `read` would have
    /// fallen back and the comparison would be a type against itself.
    private func readBothWays(_ json: String) throws -> (typed: ThreadPage, fallback: ThreadPage) {
        XCTAssertNoThrow(try JSONDecoder().decode(TimelineResponse.self, from: Data(json.utf8)))
        let document = try XCTUnwrap(JSONWire.decode(Data(json.utf8)))
        let typed = try XCTUnwrap(ThreadPageReader.read(document).successOnly)
        let fallback = try XCTUnwrap(ThreadPageReader.readShapeGuarded(document).successOnly)
        return (typed, fallback)
    }

    private static let smsRow = #"""
    {"id":"m_1","type":"sms","direction":"inbound","timestamp":"2026-08-19T09:41:00.000Z",
     "body":"On my way.","status":"received","mediaUrls":[]}
    """#

    private static let callRow = #"""
    {"id":"call_1","type":"call","direction":"inbound","timestamp":"2026-08-19T09:40:00.000Z",
     "body":"Booked a survey.","status":"completed","duration":65,"summary":"Booked a survey.",
     "hasTranscript":true}
    """#

    /// - Parameter json: the whole enveloped body, as ``ResponseEnvelope/require(_:_:)``
    ///   would hand it over.
    private func read(_ json: String) throws -> ThreadPage {
        let document = try XCTUnwrap(JSONWire.decode(Data(json.utf8)))
        return try XCTUnwrap(ThreadPageReader.read(document).successOnly)
    }
}
