import DistrictData
import DistrictModel
import Foundation
import XCTest

/// The recordings table and its consent evidence.
final class SchedulingRecordingFormatTests: XCTestCase {
    private typealias Recording = SchedulingRecordingFormat

    // MARK: - recordedWhen

    /// ⛔ THE HOUR IS ZERO-PADDED HERE AND UNPADDED IN THE BOOKINGS TABLE. Both are
    /// asserted, in two files, so a tidy-up that unified them fails rather than quietly
    /// putting this client out of step with the browser.
    func testTheRecordingStampPadsTheHour() {
        XCTAssertEqual(
            Recording.recordedWhen(createdAt: "2026-09-03T09:05:00Z", timezone: "UTC"),
            "Sep 3, 2026, 09:05"
        )
    }

    func testTheRecordingStampIsZonedAndAbsolute() {
        XCTAssertEqual(
            Recording.recordedWhen(createdAt: "2026-09-03T02:00:00Z", timezone: "America/Toronto"),
            "Sep 2, 2026, 22:00"
        )
    }

    func testAnAbsentOrUnparseableStampIsNil() {
        XCTAssertNil(Recording.recordedWhen(createdAt: nil, timezone: "UTC"))
        XCTAssertNil(Recording.recordedWhen(createdAt: "soon", timezone: "UTC"))
    }

    // MARK: - recordingDuration

    /// ⛔ ZERO IS `Not finished` AND NEVER `0 s`. A recording still running and one that
    /// failed before writing anything both arrive as zero, and neither is a completed
    /// recording of no length.
    func testZeroAndAbsentAreNotFinished() {
        XCTAssertEqual(Recording.recordingDuration(0), "Not finished")
        XCTAssertEqual(Recording.recordingDuration(nil), "Not finished")
        XCTAssertEqual(Recording.recordingDuration(-5), "Not finished")
    }

    func testTheFourDurationShapes() {
        XCTAssertEqual(Recording.recordingDuration(45), "45 s")
        XCTAssertEqual(Recording.recordingDuration(59), "59 s")
        XCTAssertEqual(Recording.recordingDuration(60), "1 min")
        XCTAssertEqual(Recording.recordingDuration(3599), "59 min")
        XCTAssertEqual(Recording.recordingDuration(3600), "1 h")
        XCTAssertEqual(Recording.recordingDuration(3900), "1 h 5 min")
    }

    /// ⚠️ MINUTES FLOOR RATHER THAN ROUND: 90 seconds is `1 min`, not `2 min`.
    func testMinutesFloorRatherThanRound() {
        XCTAssertEqual(Recording.recordingDuration(90), "1 min")
        XCTAssertEqual(Recording.recordingDuration(119), "1 min")
    }

    /// ⚠️ AN EXACT HOUR DROPS THE MINUTES rather than saying `1 h 0 min`.
    func testAnExactHourDropsTheMinutes() {
        XCTAssertEqual(Recording.recordingDuration(7200), "2 h")
    }

    // MARK: - recordingState

    func testTheThreeKnownStatesGetTheirOwnWording() {
        XCTAssertEqual(
            Recording.recordingState("active"),
            SchedulingStatusLabel(label: "Recording", kind: .inProgress)
        )
        XCTAssertEqual(
            Recording.recordingState("complete"),
            SchedulingStatusLabel(label: "Complete", kind: .success)
        )
        XCTAssertEqual(
            Recording.recordingState("failed"),
            SchedulingStatusLabel(label: "Failed", kind: .error)
        )
    }

    /// ⛔ AN UNKNOWN RECORDING STATUS IS **NOT** ECHOED, which is the opposite of what
    /// `SchedulingBookingFormat.statusLabel` does. A raw `pending_upload` in a State column
    /// reads as a fault rather than as progress.
    func testAnUnknownRecordingStatusIsNotEchoed() {
        XCTAssertEqual(
            Recording.recordingState("pending_upload"),
            SchedulingStatusLabel(label: "Unknown", kind: .pending)
        )
        XCTAssertEqual(
            SchedulingBookingFormat.statusLabel("pending_upload").label,
            "pending_upload"
        )
    }

    // MARK: - recordingWho

    func testTheBookerNameOrSomeone() throws {
        XCTAssertEqual(
            try Recording.recordingWho(SchedulingFixture.recording(bookerName: "Ada")),
            "Ada"
        )
        XCTAssertEqual(try Recording.recordingWho(SchedulingFixture.recording()), "Someone")
        XCTAssertEqual(
            try Recording.recordingWho(SchedulingFixture.recording(bookerName: "   ")),
            "Someone"
        )
    }

    // MARK: - consentDecision

    /// ⛔ `pending` IS A REAL AND COMMON STATE — the guest left before the prompt resolved
    /// — and is NEVER "granted by default". These rows are the evidence for a
    /// two-party-consent jurisdiction.
    func testTheDefaultConsentArmIsAnAbsenceAndNotAConsent() {
        XCTAssertEqual(
            Recording.consentDecision("anything_else"),
            SchedulingStatusLabel(label: "No answer recorded", kind: .pending)
        )
        XCTAssertEqual(
            Recording.consentDecision(""),
            SchedulingStatusLabel(label: "No answer recorded", kind: .pending)
        )
    }

    func testTheTwoDecidedConsents() {
        XCTAssertEqual(
            Recording.consentDecision("continue"),
            SchedulingStatusLabel(label: "Agreed to be recorded", kind: .success)
        )
        XCTAssertEqual(
            Recording.consentDecision("leave"),
            SchedulingStatusLabel(label: "Left the meeting", kind: .stopped)
        )
    }

    // MARK: - consentWho

    func testTheConsentNameThenTheIdentityThenAPlaceholder() throws {
        XCTAssertEqual(
            try Recording.consentWho(SchedulingFixture.consent(identity: "id-1", name: "Ada")),
            "Ada"
        )
        XCTAssertEqual(
            try Recording.consentWho(SchedulingFixture.consent(identity: "id-1")),
            "id-1"
        )
        XCTAssertEqual(
            try Recording.consentWho(SchedulingFixture.consent(identity: "  ", name: "  ")),
            "Unnamed participant"
        )
    }

    // MARK: - fileLabel

    /// ⚠️ ABSENT IS `None`, NOT `Stored`. A row with no proven object behind it would 404
    /// on download, and the 404 arrives as a generic unknown failure.
    func testAnAbsentFileFlagIsNoneAndNotStored() {
        XCTAssertEqual(Recording.fileLabel(true), "Stored")
        XCTAssertEqual(Recording.fileLabel(false), "None")
        XCTAssertEqual(Recording.fileLabel(nil), "None")
    }
}
