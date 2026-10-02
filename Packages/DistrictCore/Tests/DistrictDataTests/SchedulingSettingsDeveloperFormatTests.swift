import DistrictData
import DistrictModel
import Foundation
import XCTest

/// The settings tabs' labels and the developer tabs' tables.
///
/// ⚠️ TWO FORMATTERS IN ONE FILE because both are small and neither has behaviour the
/// other could be confused with; the alternative was two twenty-line files.
final class SchedulingSettingsDeveloperFormatTests: XCTestCase {
    private typealias Settings = SchedulingSettingsFormat
    private typealias Developer = SchedulingDeveloperFormat

    // MARK: - Settings tabs

    func testTheFourSettingsTabsAreInTheWebsOrder() {
        XCTAssertEqual(
            Settings.settingsTabIds,
            ["booking-page", "recordings", "profile", "notifications"]
        )
        XCTAssertEqual(
            Settings.settingsTabLabels,
            ["Booking page", "Recordings and notes", "Your profile", "Your notifications"]
        )
        XCTAssertEqual(Settings.settingsTabIds.count, Settings.settingsTabLabels.count)
    }

    // MARK: - Value labels

    /// ⚠️ THE EXAMPLE TIME IS PART OF THE LABEL: "12-hour" alone is ambiguous.
    func testTheTimeFormatLabelsCarryTheirExamples() {
        XCTAssertEqual(Settings.timeFormatLabel("12h"), "12-hour (2:30 pm)")
        XCTAssertEqual(Settings.timeFormatLabel("24h"), "24-hour (14:30)")
    }

    func testTheDateFormatLabelsAreExamples() {
        XCTAssertEqual(Settings.dateFormatLabel("dmy"), "31/12/2026")
        XCTAssertEqual(Settings.dateFormatLabel("mdy"), "12/31/2026")
        XCTAssertEqual(Settings.dateFormatLabel("ymd"), "2026-12-31")
    }

    /// ⚠️ AN UNKNOWN STORED VALUE IS ECHOED rather than blanked, so a profile carrying
    /// something this build does not know still shows what it is set to.
    func testAnUnknownFormatIsEchoed() {
        XCTAssertEqual(Settings.timeFormatLabel("36h"), "36h")
        XCTAssertEqual(Settings.dateFormatLabel("ydm"), "ydm")
    }

    /// ⛔ SUNDAY-INDEXED, UNLIKE THE MONDAY-FIRST GRID ONE SCREEN AWAY. Asserted next to
    /// the grid's table so the two cannot be swapped.
    func testTheWeekStartTableIsSundayIndexedUnlikeTheGrid() {
        XCTAssertEqual(Settings.weekStartLabel(0), "Sunday")
        XCTAssertEqual(Settings.weekStartLabel(1), "Monday")
        XCTAssertEqual(Settings.weekStartLabel(6), "Saturday")
        XCTAssertEqual(SchedulingHoursFormat.weekDayNames[0], "Monday")
    }

    func testAnOutOfRangeWeekStartIsItsOwnNumber() {
        XCTAssertEqual(Settings.weekStartLabel(9), "9")
        XCTAssertEqual(Settings.weekStartLabel(-1), "-1")
    }

    // MARK: - localeLabel

    func testTheLocaleResolvesThroughTheSupportedList() throws {
        let supported = try [
            SchedulingFixture.decode(SchedulingLocaleOption.self, #"{"code":"fr","name":"Français"}"#),
        ]
        XCTAssertEqual(Settings.localeLabel(code: "fr", supported: supported), "Français")
    }

    /// ⚠️ AN UNSUPPORTED CODE IS SHOWN RAW. A fallback locale the tenancy no longer
    /// supports is a real configuration problem, and hiding it would read as unset.
    func testAnUnsupportedLocaleIsShownRaw() {
        XCTAssertEqual(Settings.localeLabel(code: "de", supported: []), "de")
        XCTAssertEqual(Settings.localeLabel(code: "de", supported: nil), "de")
    }

    func testAnEmptyLocaleIsNotSet() {
        XCTAssertEqual(Settings.localeLabel(code: "", supported: nil), "Not set")
        XCTAssertEqual(Settings.localeLabel(code: "  ", supported: nil), "Not set")
    }

    /// ⚠️ A BLANK NAME FALLS BACK TO THE CODE.
    func testABlankLocaleNameFallsBackToTheCode() throws {
        let supported = try [
            SchedulingFixture.decode(SchedulingLocaleOption.self, #"{"code":"fr","name":""}"#),
        ]
        XCTAssertEqual(Settings.localeLabel(code: "fr", supported: supported), "fr")
    }

    // MARK: - recordingDescription

    /// ⛔ THE SENTENCE CHANGES WITH STORAGE READINESS AND NOT WITH THE TOGGLE. A region
    /// with no storage cannot record whatever the switch says.
    func testTheRecordingSentenceTracksStorageAndNotTheToggle() throws {
        let notReady = try SchedulingFixture.storage(enabled: true, ready: false)
        XCTAssertTrue(Settings.recordingDescription(notReady).contains("not enabled for this region"))

        let ready = try SchedulingFixture.storage(enabled: false, ready: true)
        XCTAssertTrue(Settings.recordingDescription(ready).hasPrefix("Meetings held on the built-in video"))
    }

    /// ⚠️ AN ABSENT READINESS FLAG IS TREATED AS READY, because the comparison is against
    /// `false` explicitly — an older payload should not claim the region is broken.
    func testAnAbsentReadinessFlagReadsAsReady() throws {
        let unknown = try SchedulingFixture.storage(enabled: true, ready: nil)
        XCTAssertTrue(Settings.recordingDescription(unknown).hasPrefix("Meetings held"))
    }

    // MARK: - Notifications

    func testTheTwoGroupsHoldSevenSwitchesInTheWebsOrder() {
        XCTAssertEqual(Settings.notificationGroups.map(\.heading), ["As an attendee", "As a host"])
        XCTAssertEqual(Settings.notificationGroups[0].switches.count, 4)
        XCTAssertEqual(Settings.notificationGroups[1].switches.count, 3)
        XCTAssertEqual(
            Settings.notificationGroups[0].switches.map(\.label),
            ["A booking is confirmed", "A booking is cancelled", "A booking is moved", "A booking is coming up"]
        )
        XCTAssertEqual(
            Settings.notificationGroups[1].switches.map(\.label),
            ["Somebody books you", "Somebody cancels", "Somebody moves their booking"]
        )
    }

    /// ⛔ EVERY FIELD IN THE TABLE RESOLVES ON A REAL PROFILE. This is what stops the
    /// table and the DTO drifting: a renamed switch would answer nil and draw nothing,
    /// which is invisible without this assertion.
    func testEveryTabulatedSwitchResolvesOnAProfile() throws {
        let me = try SchedulingFixture.me(notifications: true)
        for group in Settings.notificationGroups {
            for entry in group.switches {
                XCTAssertEqual(Settings.notificationValue(entry.field, on: me), true, entry.field)
            }
        }
    }

    func testTheSwitchesReadFalseWhenTheyAreOff() throws {
        let me = try SchedulingFixture.me(notifications: false)
        XCTAssertEqual(Settings.notificationValue("notify_confirmation", on: me), false)
        XCTAssertEqual(Settings.notificationValue("notify_host_reschedule", on: me), false)
    }

    /// ⚠️ AN UNKNOWN FIELD IS nil AND NOT false: "we do not know" and "it is off" are
    /// different, and drawing the second would assert a choice nobody made.
    func testAnUnknownNotificationFieldIsNil() throws {
        XCTAssertNil(try Settings.notificationValue("notify_nothing", on: SchedulingFixture.me()))
    }

    // MARK: - Developer tabs

    func testTheThreeDeveloperTabsAreInTheWebsOrder() {
        XCTAssertEqual(Developer.tabIds, ["keys", "apps", "webhooks"])
        XCTAssertEqual(Developer.tabLabels, ["API keys", "Connected apps", "Webhooks"])
    }

    /// ⛔ THE PLACEHOLDER IS LITERAL AND A REAL KEY MUST NEVER TAKE ITS PLACE. A copied
    /// snippet ends up in a file, a chat message and a screenshot.
    func testTheKeyPlaceholderIsLiteral() {
        XCTAssertEqual(Developer.mcpKeyPlaceholder, "<your API key>")
    }

    /// ⚠️ THE EDITOR LISTS `allCases`, SO THE DECLARATION ORDER IS THE SCREEN'S ORDER.
    func testTheSevenWebhookEventsAreInTheWebsOrder() {
        XCTAssertEqual(
            SchedulingWebhookEvent.allCases.map(\.rawValue),
            [
                "booking.created", "booking.cancelled", "booking.rescheduled", "booking.reminder",
                "recording.completed", "transcript.ready", "notes.ready",
            ]
        )
    }

    /// ⛔ ALL SIX PERSONAL-DATA FIELDS, AND THE FOUR THAT ALSO DEFAULT OFF ARE A SUBSET.
    func testThePersonalDataFieldsIncludeTheHostAndTheAttendee() {
        for field in ["host_name", "host_email", "attendee_name", "attendee_email", "attendee_timezone", "answers"] {
            XCTAssertTrue(Developer.isPersonalDataField(field), field)
        }
        XCTAssertFalse(Developer.isPersonalDataField("start_at"))
        XCTAssertEqual(Developer.attendeeWebhookFields.count, 4)
        XCTAssertEqual(Developer.personalDataWebhookFields.count, 6)
    }

    // MARK: - mcpUrl

    /// ⚠️ EMPTY RATHER THAN A GUESS while a tenancy is still provisioning.
    func testTheMcpUrlIsEmptyUntilTheHostIsKnown() {
        XCTAssertEqual(Developer.mcpUrl(publicHost: "acme.example.com"), "https://acme.example.com/mcp")
        XCTAssertEqual(Developer.mcpUrl(publicHost: ""), "")
        XCTAssertEqual(Developer.mcpUrl(publicHost: "   "), "")
    }

    // MARK: - deliveryOutcome

    /// ⛔ "No answer" AND "Rejected with 500" ARE DIFFERENT DIAGNOSES. The first points at
    /// DNS, a firewall or a dead host; the second at the receiving application. There is
    /// no error text anywhere, so this label is the whole diagnosis.
    func testAFailedDeliveryDistinguishesNoAnswerFromARejection() {
        XCTAssertEqual(
            Developer.deliveryOutcome(status: "failed", responseStatus: 500),
            SchedulingStatusLabel(label: "Rejected with 500", kind: .error)
        )
        XCTAssertEqual(
            Developer.deliveryOutcome(status: "failed", responseStatus: nil),
            SchedulingStatusLabel(label: "No answer", kind: .error)
        )
    }

    /// ⚠️ A STORED ZERO IS TREATED AS ABSENT: no HTTP response is status 0, so it is the
    /// fork's way of recording that there was none.
    func testAZeroResponseStatusIsTreatedAsNoAnswer() {
        XCTAssertEqual(
            Developer.deliveryOutcome(status: "failed", responseStatus: 0).label,
            "No answer"
        )
    }

    func testTheSettledDeliveryStatuses() {
        XCTAssertEqual(
            Developer.deliveryOutcome(status: "success", responseStatus: 200),
            SchedulingStatusLabel(label: "Delivered", kind: .success)
        )
        XCTAssertEqual(
            Developer.deliveryOutcome(status: "pending", responseStatus: nil),
            SchedulingStatusLabel(label: "Waiting", kind: .pending)
        )
        XCTAssertEqual(
            Developer.deliveryOutcome(status: "retrying", responseStatus: nil),
            SchedulingStatusLabel(label: "retrying", kind: .info)
        )
    }

    // MARK: - stamp

    /// ⛔ TWELVE-HOUR, WHICH IS THE ONE PLACE ON THIS SURFACE THAT IS, AND IT IS INHERITED
    /// RATHER THAN CHOSEN. The web's `stamp` does not override `formatInUserTimezone`'s
    /// `hour12: true` default, so these four columns render an AM/PM clock while every
    /// other scheduling table renders a 24-hour one.
    func testTheDeveloperStampIsTwelveHour() {
        XCTAssertEqual(
            Developer.stamp("2026-09-12T14:05:00Z", timezone: "UTC"),
            "Sep 12, 2026, 02:05 PM"
        )
        XCTAssertEqual(
            Developer.stamp("2026-09-12T09:05:00Z", timezone: "UTC"),
            "Sep 12, 2026, 09:05 AM"
        )
    }

    /// ⚠️ MIDNIGHT AND NOON BOTH RENDER AS 12, which is what a 12-hour clock does.
    func testMidnightAndNoonBothRenderAsTwelve() {
        XCTAssertEqual(Developer.stamp("2026-09-12T00:05:00Z", timezone: "UTC"), "Sep 12, 2026, 12:05 AM")
        XCTAssertEqual(Developer.stamp("2026-09-12T12:05:00Z", timezone: "UTC"), "Sep 12, 2026, 12:05 PM")
    }

    /// ⚠️ THE ABSENT MARKER IS PER COLUMN AND THE DEFAULT IS AN EM DASH. `Never` and
    /// `Not tried yet` are the callers' and are not interchangeable.
    func testTheAbsentMarkerDefaultsToAnEmDashAndIsOverridable() {
        XCTAssertEqual(Developer.stamp(nil, timezone: "UTC"), "—")
        XCTAssertEqual(Developer.stamp("", timezone: "UTC"), "—")
        XCTAssertEqual(Developer.stamp(nil, timezone: "UTC", absent: "Never"), "Never")
        XCTAssertEqual(Developer.stamp(nil, timezone: "UTC", absent: "Not tried yet"), "Not tried yet")
    }

    /// ⚠️ AN UNPARSEABLE VALUE IS `Unknown Date`, NOT THE ABSENT MARKER. The row HAS a
    /// value and it could not be read, which is a different fact from having none.
    func testAnUnparseableStampIsNotTheAbsentMarker() {
        XCTAssertEqual(Developer.stamp("whenever", timezone: "UTC", absent: "Never"), "Unknown Date")
    }

    func testTheDeveloperStampIsZoned() {
        XCTAssertEqual(
            Developer.stamp("2026-09-12T02:05:00Z", timezone: "America/Toronto"),
            "Sep 11, 2026, 10:05 PM"
        )
    }
}
