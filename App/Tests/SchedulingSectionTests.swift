@testable import DistrictAI
import DistrictModel
import DistrictNetwork
import XCTest

/// The scheduling section vocabulary: its list, its URL segments and its role bars.
///
/// ⛔ THE ROLE ASSERTIONS ARE THE POINT OF THIS FILE. Every read on all nine sections is
/// `viewer`-level today, which makes the gate look like a no-op and makes it the exact
/// thing a later change breaks silently — a section whose read is narrowed to `client`
/// would simply stop appearing for a viewer with nothing to say so. These tests pin the
/// CURRENT answer so that narrowing one becomes a deliberate edit here.
final class SchedulingSectionTests: XCTestCase {
    /// ⛔ NINE ROWS ON THE HUB, AND `hub` IS NOT ONE OF THEM. It is the screen the list is
    /// on; a row leading to itself would be a loop.
    func test_IOS_SCHSEC_01_theHubListsNineSectionsAndNotItself() {
        XCTAssertEqual(SchedulingSection.listed.count, 9)
        XCTAssertFalse(SchedulingSection.listed.contains(.hub))
    }

    /// ⛔ NEITHER DRILL-DOWN IS ON THE HUB. Neither can be addressed without an identifier
    /// the hub does not hold, so a row for one would link to a guess.
    func test_IOS_SCHSEC_02_theDrillDownsAreNotHubRows() {
        XCTAssertFalse(SchedulingSection.listed.contains(.eventType(slug: "intro")))
        XCTAssertFalse(SchedulingSection.listed.contains(.booking(id: "b1")))
    }

    /// ⛔ THE SEGMENTS ARE THE WEBSITE'S DIRECTORY NAMES VERBATIM, so a link copied out of
    /// a browser resolves. `eventTypes` would be a segment no page answers.
    func test_IOS_SCHSEC_03_theSegmentsMatchTheWebsDirectoryNames() {
        XCTAssertEqual(
            SchedulingSection.listed.map { $0.pathSegment ?? "" },
            [
                "overview", "event-types", "hours", "bookings", "calendar",
                "team", "recordings", "settings", "developer",
            ]
        )
    }

    /// ⚠️ THE HUB AND THE TWO DRILL-DOWNS HAVE NO SEGMENT: the hub IS the bare path, and
    /// neither drill-down has a published URL to copy.
    func test_IOS_SCHSEC_04_theHubAndTheDrillDownsHaveNoSegment() {
        XCTAssertNil(SchedulingSection.hub.pathSegment)
        XCTAssertNil(SchedulingSection.eventType(slug: "intro").pathSegment)
        XCTAssertNil(SchedulingSection.booking(id: "b1").pathSegment)
    }

    /// Every listed section round-trips through its own segment.
    func test_IOS_SCHSEC_05_everySegmentResolvesBackToItsSection() {
        for section in SchedulingSection.listed {
            XCTAssertEqual(SchedulingSection.forPathSegment(section.pathSegment), section)
        }
    }

    /// ⛔ AN UNKNOWN SEGMENT IS THE HUB AND NEVER A FAILURE. The claim is already narrowed
    /// to scheduling, so the hub IS the surface the URL named, one level up.
    func test_IOS_SCHSEC_06_anUnknownSegmentLandsOnTheHub() {
        XCTAssertEqual(SchedulingSection.forPathSegment("nope"), .hub)
        XCTAssertEqual(SchedulingSection.forPathSegment(""), .hub)
        XCTAssertEqual(SchedulingSection.forPathSegment(nil), .hub)
    }

    /// ⛔ EVERY READ ON EVERY SECTION IS `viewer`-LEVEL TODAY. See the ⛔ at the top of this
    /// file for why that is worth asserting rather than assuming.
    func test_IOS_SCHSEC_07_everySectionsReadAdmitsAViewer() {
        for section in SchedulingSection.listed {
            XCTAssertEqual(section.minReadRole, .viewer, "\(section)")
        }
        XCTAssertEqual(SchedulingSection.hub.minReadRole, .viewer)
    }

    /// ⛔ AND THE CLAIM ABOVE IS CHECKED AGAINST THE CATALOG RATHER THAN RESTATED. Every op
    /// these nine screens actually send is listed here and asserted `viewer` against
    /// ``SchedulingAdminOp/minRole`` — so if the server narrows one, this fails with the
    /// op's name rather than the section quietly vanishing from the hub.
    func test_IOS_SCHSEC_08_everyOpTheSectionsSendIsAViewerRead() {
        let reads: [SchedulingAdminOp] = [
            .meGet,
            .eventTypesList, .eventTypesGet, .eventTypesHostsGet, .eventTypesQuestionsList,
            .availabilityRulesList, .availabilityOverridesList,
            .bookingsList, .bookingsAnswers, .bookingsNotes, .bookingsTranscript,
            .calendarStatus, .calendarConnectionsCalendarsGet, .zoomStatus,
            .usersList, .teamsList,
            .recordingsList, .recordingsConsent,
            .settingsBrandingGet, .settingsStorageGet, .settingsNotetakerGet, .settingsLlmGet,
            .apiKeysList, .oauthConnectionsList, .webhooksList, .webhooksDeliveries,
        ]
        for op in reads {
            XCTAssertEqual(op.minRole, .viewer, op.rawValue)
            XCTAssertFalse(op.isWrite, op.rawValue)
        }
    }

    /// ⛔ THE RECORDING DOWNLOAD IS THE ONE AFFORDANCE NARROWER THAN ITS LIST, which is the
    /// whole reason the recordings screen reads a role at all. Asserted as a PAIR so the
    /// asymmetry cannot be tidied away from either side.
    func test_IOS_SCHSEC_09_theRecordingListAdmitsAViewerAndTheDownloadDoesNot() {
        XCTAssertEqual(SchedulingAdminOp.recordingsList.minRole, .viewer)
        // ⚠️ The download is not an `op` at all — it is a 302 on its own route — so the
        // bar is asserted through the gate the screen actually uses.
        XCTAssertFalse(WorkspaceRole.allowsMutation(.viewer))
        XCTAssertTrue(WorkspaceRole.allowsMutation(.client))
        XCTAssertTrue(WorkspaceRole.allowsMutation(.agency))
    }

    /// ⛔ AND IT FAILS CLOSED ON A ROLE THAT DID NOT PARSE, which is the correct direction
    /// for a control that takes a customer conversation off the platform.
    func test_IOS_SCHSEC_10_anUnparseableRoleMayNotDownload() {
        XCTAssertFalse(WorkspaceRole.allowsMutation(nil))
    }
}
