import DistrictModel
import Foundation
import XCTest

/// The `recordings.*` row DTOs.
///
/// ⛔ INLINE BYTES, FOR THE REASON `SchedulingAdminSettingsTests` GIVES: the
/// contract gate pins the shape of the committed corpus and cannot pin a branch
/// those bytes do not contain.
final class SchedulingAdminRecordingsTests: XCTestCase {
    private let decoder = JSONDecoder()

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }

    /// ⛔ ONLY `id` AND `status` ARE GUARANTEED. A capture that FAILED has no room,
    /// no duration, no file and no booker, because none of them was ever written —
    /// so a DTO that required `booking_id` would throw on the one row an operator
    /// most needs to see, and the failure would read as "recordings are broken".
    func testAFailedRecordingDecodesFromTwoKeys() throws {
        let row = try decode(SchedulingRecording.self, #"{"id":"rec_2","status":"failed"}"#)
        XCTAssertEqual(row.id, "rec_2")
        XCTAssertEqual(row.status, "failed")
        XCTAssertNil(row.bookingId)
        XCTAssertNil(row.room)
        XCTAssertNil(row.durationS)
        XCTAssertNil(row.hasFile)
        XCTAssertNil(row.createdAt)
        XCTAssertNil(row.bookerName)
    }

    /// The other polarity, and every `CodingKeys` entry with it.
    func testAReadyRecordingMapsEverySnakeCaseKey() throws {
        let row = try decode(
            SchedulingRecording.self,
            #"""
            {"id":"rec_1","booking_id":"bk_1","room":"booking-bk_1","status":"ready",
             "duration_s":1793,"has_file":true,"created_at":"2026-09-14T13:30:00Z",
             "booker_name":"Dana Booker"}
            """#
        )
        XCTAssertEqual(row.bookingId, "bk_1")
        XCTAssertEqual(row.room, "booking-bk_1")
        XCTAssertEqual(row.durationS, 1793)
        XCTAssertEqual(row.hasFile, true)
        XCTAssertEqual(row.createdAt, "2026-09-14T13:30:00Z")
        XCTAssertEqual(row.bookerName, "Dana Booker")
    }

    /// ⛔ A FILE IS NOT IMPLIED BY `status == "ready"`. A row whose object was
    /// reaped by retention keeps its status and loses its file, and the download
    /// route answers 404 for it — so a Play button drawn off the status alone fails
    /// inside the player rather than being absent from the row.
    func testAReadyRecordingCanReportNoFile() throws {
        let row = try decode(SchedulingRecording.self, #"{"id":"rec_3","status":"ready","has_file":false}"#)
        XCTAssertEqual(row.status, "ready")
        XCTAssertEqual(row.hasFile, false)
    }

    /// ⚠️ `id` AND `status` ARE REQUIRED. Stated because "make it Optional" is the
    /// reflex fix for a decode failure, and a row with no id addresses nothing.
    func testARecordingWithoutAnIdIsRefused() {
        XCTAssertThrowsError(try decode(SchedulingRecording.self, #"{"status":"ready"}"#))
    }

    /// ⛔ THE CONTAINER KEY IS `recordings`, NOT `items`, AND THIS IS THE ONE LIST
    /// ON THE SURFACE WHERE THAT IS TRUE. Reading it through ``SchedulingItems``
    /// throws a missing-key error that presents as an outage.
    func testTheListContainerIsNamedRecordings() throws {
        let list = try decode(
            SchedulingRecordingList.self,
            #"{"recordings":[{"id":"rec_1","status":"ready"},{"id":"rec_2","status":"failed"}]}"#
        )
        XCTAssertEqual(list.recordings.map(\.id), ["rec_1", "rec_2"])
        XCTAssertThrowsError(try decode(
            SchedulingRecordingList.self,
            #"{"items":[{"id":"rec_1","status":"ready"}]}"#
        ))
    }

    /// ⚠️ AN EMPTY LIST IS A VALID ANSWER AND NOT AN ABSENCE — a tenancy that has
    /// never recorded anything.
    func testAnEmptyRecordingListDecodes() throws {
        XCTAssertTrue(try decode(SchedulingRecordingList.self, #"{"recordings":[]}"#).recordings.isEmpty)
    }

    /// ⛔ A PARTIAL FAILURE IS A **200** AND `failed` IS THE ONLY PLACE IT IS
    /// REPORTED. Both numbers are required: a body that carried only `deleted`
    /// would let a screen say "all deleted" over recordings that are still there.
    func testTheBulkDeleteTallyRequiresBothNumbers() throws {
        let tally = try decode(SchedulingRecordingsDeleted.self, #"{"deleted":4,"failed":1}"#)
        XCTAssertEqual(tally.deleted, 4)
        XCTAssertEqual(tally.failed, 1)
        XCTAssertThrowsError(try decode(SchedulingRecordingsDeleted.self, #"{"deleted":4}"#))
    }

    /// ⛔ `pending` IS A REAL, COMMON STATE — the guest left before the prompt
    /// resolved — AND IS NEVER "GRANTED BY DEFAULT". An absent `decided_at` beside
    /// it is the pair that makes the row readable: a decision with no timestamp has
    /// not been made.
    func testAPendingConsentCarriesNeitherANameNorATimestamp() throws {
        let consents = try decode(
            SchedulingRecordingConsents.self,
            #"""
            {"consents":[
              {"identity":"host-sched-user","name":"Contract Member","decision":"granted",
               "decided_at":"2026-09-14T13:00:05Z"},
              {"identity":"guest-dana","decision":"pending"}]}
            """#
        )
        XCTAssertEqual(consents.consents.count, 2)
        XCTAssertEqual(consents.consents[0].name, "Contract Member")
        XCTAssertEqual(consents.consents[0].decidedAt, "2026-09-14T13:00:05Z")
        XCTAssertEqual(consents.consents[0].decision, "granted")
        XCTAssertNil(consents.consents[1].name)
        XCTAssertNil(consents.consents[1].decidedAt)
        XCTAssertEqual(consents.consents[1].identity, "guest-dana")
    }

    /// ⚠️ `identity` AND `decision` ARE REQUIRED. A consent row that cannot say WHO
    /// or WHAT is not evidence of anything, which is the only thing this op exists
    /// to produce.
    func testAConsentRowWithoutADecisionIsRefused() {
        XCTAssertThrowsError(try decode(SchedulingRecordingConsent.self, #"{"identity":"guest-dana"}"#))
    }
}
