import ContractGateSupport
import DistrictModel
import Foundation
import XCTest

/// Per-fixture assertions for the two meetings bodies.
///
/// ⛔ THE ENVELOPE ASSERTION IS THE POINT OF THIS FILE. Both routes answer
/// WITHOUT a `success` flag and they do not even share a top-level shape — the
/// list is a bare ARRAY, the detail a bare OBJECT — so the mistake this file
/// exists to prevent is a one-line copy of an envelope check from any
/// neighbouring surface, which would reject every healthy response as contract
/// drift. It is asserted here rather than described in a comment, because a
/// comment cannot fail.
final class MeetingsContractTests: XCTestCase {
    // MARK: - The list is a bare array

    /// ⛔ A TOP-LEVEL ARRAY, NOT AN ENVELOPE, ASSERTED ON THE RAW BYTES. The gate
    /// already proves `[MeetingSummary]` decodes the fixture, but that would also
    /// pass the day someone wrapped the rows in an object and changed the DTO to
    /// match — so this reads the committed document itself and requires the top
    /// level to be an array with no `success` anywhere on it. That is what a
    /// later envelope "for consistency" would have to get past.
    func testTheMeetingsListIsATopLevelArrayWithNoEnvelopeToCheck() throws {
        let data = try ContractFixtures.read("district-meetings.json")
        let raw = try JSONSerialization.jsonObject(with: data)

        let rows = try XCTUnwrap(raw as? [Any], "⛔ `NextResponse.json(results)` — a bare array")
        XCTAssertEqual(rows.count, 2)
        XCTAssertNil(raw as? [String: Any], "an object here would mean an envelope arrived")
        for row in rows {
            let object = try XCTUnwrap(row as? [String: Any])
            XCTAssertNil(object["success"], "no row carries a flag either")
        }
    }

    /// ⛔ THE LIST IS A PROJECTION AND IT RENAMES AS IT RESHAPES. `summary`
    /// arrives as `summaryPreview` truncated to 220 characters and `participants`
    /// as the integer `participantCount`; neither original name is on the wire
    /// here, so a client modelling this from the detail's shape fails to decode
    /// every row. ⚠️ The preview really is a preview — asserted at exactly 220 —
    /// which is what stops a screen presenting it as the minutes.
    func testTheListRowIsATruncatedProjectionRatherThanTheMeetingRow() throws {
        let rows = try StrictDecodeVerifier.verify(
            fixture: "district-meetings.json",
            as: [MeetingSummary].self
        )
        let completed = try XCTUnwrap(rows.first { $0.id == "meeting_contract_completed" })

        XCTAssertEqual(completed.summaryPreview?.count, 220, "⛔ a preview, never the minutes")
        XCTAssertEqual(completed.participantCount, 2)
        XCTAssertEqual(completed.durationSec, 2520)
        XCTAssertEqual(completed.title, "Weekly review")
        XCTAssertNotNil(completed.endedAt)
    }

    /// ⛔ THE IN-PROGRESS ROW IS THE ORDINARY CASE, NOT AN EDGE ONE, and it is
    /// the row most likely to be at the TOP of a live user's list. The Companion
    /// writes the minutes when the room closes, so a meeting still running has no
    /// title, no end, no preview and a zero duration — which is stamped at the
    /// end rather than accumulated, so 0 does not mean "just started".
    ///
    /// ⚠️ `participantCount: 0` IS PRESENT RATHER THAN OMITTED: the route writes
    /// `Array.isArray(participants) ? length : 0`, so a null `Json?` column
    /// counts as zero instead of dropping the key or throwing.
    func testAnInProgressMeetingNullsItsTitleEndAndPreviewTogether() throws {
        let rows = try StrictDecodeVerifier.verify(
            fixture: "district-meetings.json",
            as: [MeetingSummary].self
        )
        let live = try XCTUnwrap(rows.first { $0.id == "meeting_contract_live" })

        XCTAssertEqual(live.status, "in-progress")
        XCTAssertNil(live.title, "nothing generates one")
        XCTAssertNil(live.endedAt)
        XCTAssertNil(live.summaryPreview, "⛔ no minutes until the room closes")
        XCTAssertEqual(live.durationSec, 0, "⚠️ stamped at the end, not elapsed time")
        XCTAssertEqual(live.participantCount, 0)
        XCTAssertNotNil(live.startedAt, "it is running, so it started")
    }

    // MARK: - The detail is a bare object

    /// ⛔ FOUR FIELDS THE LIST NEVER SENDS, AND NEITHER OF THE LIST'S TWO RENAMED
    /// KEYS. `roomSid`, `transcript`, `actionItems` and `workspaceId` exist only
    /// here; `summaryPreview` and `participantCount` exist only there. The
    /// asymmetry runs both ways, which is why this client carries two models.
    ///
    /// ⛔ AND THE FULL MINUTES, NOT THE PREVIEW. If the two were ever equal the
    /// truncation assertion in the list test would be measuring nothing.
    func testTheDetailIsTheWholeRowAndCarriesTheFullMinutes() throws {
        let detail = try StrictDecodeVerifier.verify(
            fixture: "district-meeting-detail.json",
            as: MeetingDetail.self
        )

        XCTAssertEqual(detail.roomSid, "RM_contractmeeting01")
        XCTAssertEqual(detail.workspaceId, "ws-contract-test")
        XCTAssertNotNil(detail.transcript, "⚠️ the complete conversation, unredacted")
        XCTAssertNotNil(detail.actionItems)
        XCTAssertNotNil(detail.participants)
        let summary = try XCTUnwrap(detail.summary)
        XCTAssertGreaterThan(summary.count, 220, "⛔ the minutes, not the 220-character preview")
    }

    /// ⛔ NO RECORDING KEY, AND A ROOMS SCREEN MUST NOT PROMISE PLAYBACK. The
    /// `Meeting` model has no recording column at all — its artefacts are the
    /// summary and the transcript, both written by the Companion — and neither
    /// meetings route has a recording sibling. The one recording surface on this
    /// API is `calls/{id}/recording`, a telephone call answering a 302 on
    /// `RedirectEndpoints`. Asserted on the raw bytes so the absence is a
    /// committed fact rather than a reading of the schema.
    func testNoMeetingBodyCarriesARecordingForAScreenToOffer() throws {
        let data = try ContractFixtures.read("district-meeting-detail.json")
        let detail = try JSONSerialization.jsonObject(with: data)
        let keys = try XCTUnwrap(detail as? [String: Any]).keys.map { $0.lowercased() }

        XCTAssertFalse(keys.contains(where: { $0.contains("record") }), "⛔ nothing here to play")
        XCTAssertFalse(keys.contains(where: { $0.contains("audio") }))
        XCTAssertFalse(keys.contains(where: { $0.contains("url") }))
    }

    /// ⛔ THE TWO MODELS CANNOT READ EACH OTHER'S PAYLOAD, WHICH IS THE CLAIM THE
    /// TWO FIXTURES REST ON. Stated as a test because "the detail is a superset
    /// of the list row" is the natural assumption and it is false in both
    /// directions: a summary is missing `summaryPreview` and `participantCount`,
    /// a detail row is missing `roomSid`, `workspaceId` and the rest.
    func testNeitherMeetingModelDecodesTheOthersDocument() throws {
        let listRow = try ContractFixtures.read("district-meetings.json")
        let detailRow = try ContractFixtures.read("district-meeting-detail.json")

        XCTAssertThrowsError(try JSONDecoder().decode([MeetingDetail].self, from: listRow))
        XCTAssertThrowsError(try JSONDecoder().decode(MeetingSummary.self, from: detailRow))
    }
}
