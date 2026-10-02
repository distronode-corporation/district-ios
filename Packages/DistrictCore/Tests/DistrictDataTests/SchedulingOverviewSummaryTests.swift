import DistrictData
import DistrictModel
import Foundation
import XCTest

/// The overview register's five rows.
///
/// ⛔ THE ODD-LOOKING RULES ARE ASSERTED RATHER THAN THE TIDY ONES, because the tidy ones
/// are what a rewrite would produce. A two-day run staying a comma list, `active` never
/// pluralising and an unresolved slug being shown raw all read as bugs and all match the
/// browser; a test that only covered the obvious cases would let every one of them be
/// "fixed" into a difference an operator can see.
final class SchedulingOverviewSummaryTests: XCTestCase {
    private typealias Summary = SchedulingOverviewSummary

    // MARK: - displayTime

    func testDisplayTimeDropsTheLeadingZeroFromTheHourOnly() {
        XCTAssertEqual(Summary.displayTime("09:00"), "9:00")
        XCTAssertEqual(Summary.displayTime("17:05"), "17:05")
        XCTAssertEqual(Summary.displayTime("00:30"), "0:30")
    }

    /// ⚠️ A VALUE WITH NO COLON IS NOT A TIME THIS FUNCTION UNDERSTANDS, and mangling it
    /// would hide that from whoever has to debug the row.
    func testDisplayTimeLeavesSomethingWithoutAColonAlone() {
        XCTAssertEqual(Summary.displayTime("0900"), "0900")
        XCTAssertEqual(Summary.displayTime(""), "")
    }

    /// ⚠️ AN HOUR THAT IS NOT A NUMBER IS PASSED THROUGH, not zeroed. `Int(_:)` answers
    /// nil and the source's `Number.parseInt` would answer `NaN`; both fall back to the
    /// raw text, so a corrupt rule shows what the server actually sent rather than a
    /// plausible-looking `0:30`. This is the `?? String(pieces[0])` arm, and nothing else
    /// in the suite reaches it.
    func testDisplayTimeLeavesAnHourThatIsNotANumberAlone() {
        XCTAssertEqual(Summary.displayTime("ab:30"), "ab:30")
        XCTAssertEqual(Summary.displayTime(":30"), ":30")
    }

    // MARK: - summarizeWorkingHours

    /// The headline case: five identical weekdays collapse to a range.
    func testFiveIdenticalWeekdaysBecomeARange() throws {
        let rules = try (1 ... 5).map {
            try SchedulingFixture.rule(id: "r\($0)", dayOfWeek: $0, start: "09:00", end: "17:00")
        }
        XCTAssertEqual(Summary.summarizeWorkingHours(rules), "Mon to Fri, 9:00 to 17:00")
    }

    /// ⛔ EXACTLY TWO CONSECUTIVE DAYS STAY A COMMA LIST. The range form needs three, and
    /// this is the assertion that stops somebody "fixing" it to `Mon to Tue`.
    func testTwoConsecutiveDaysStayACommaList() throws {
        let rules = try [1, 2].map {
            try SchedulingFixture.rule(id: "r\($0)", dayOfWeek: $0, start: "09:00", end: "17:00")
        }
        XCTAssertEqual(Summary.summarizeWorkingHours(rules), "Mon, Tue, 9:00 to 17:00")
    }

    func testNonConsecutiveDaysStayACommaListHoweverManyThereAre() throws {
        let rules = try [1, 3, 5].map {
            try SchedulingFixture.rule(id: "r\($0)", dayOfWeek: $0, start: "09:00", end: "17:00")
        }
        XCTAssertEqual(Summary.summarizeWorkingHours(rules), "Mon, Wed, Fri, 9:00 to 17:00")
    }

    /// ⚠️ GROUPS ARE JOINED WITH `; ` AND ORDERED BY THEIR FIRST DAY.
    func testTwoDifferentShapesBecomeTwoClauses() throws {
        var rules = try (1 ... 5).map {
            try SchedulingFixture.rule(id: "r\($0)", dayOfWeek: $0, start: "09:00", end: "17:00")
        }
        try rules.append(SchedulingFixture.rule(id: "r6", dayOfWeek: 6, start: "10:00", end: "14:00"))
        XCTAssertEqual(
            Summary.summarizeWorkingHours(rules),
            "Mon to Fri, 9:00 to 17:00; Sat, 10:00 to 14:00"
        )
    }

    /// ⚠️ TWO WINDOWS ON ONE DAY READ "a and b", sorted by start time regardless of the
    /// order the rules arrived in.
    func testTwoWindowsOnOneDayAreJoinedWithAnd() throws {
        let rules = try [
            SchedulingFixture.rule(id: "r2", dayOfWeek: 1, start: "13:00", end: "17:00"),
            SchedulingFixture.rule(id: "r1", dayOfWeek: 1, start: "09:00", end: "12:00"),
        ]
        XCTAssertEqual(
            Summary.summarizeWorkingHours(rules),
            "Mon, 9:00 to 12:00 and 13:00 to 17:00"
        )
    }

    /// ⚠️ THREE WINDOWS USE COMMAS THEN `and`, WITH NO OXFORD COMMA.
    func testThreeWindowsUseCommasThenAnd() throws {
        let rules = try [
            SchedulingFixture.rule(id: "r1", dayOfWeek: 1, start: "09:00", end: "10:00"),
            SchedulingFixture.rule(id: "r2", dayOfWeek: 1, start: "11:00", end: "12:00"),
            SchedulingFixture.rule(id: "r3", dayOfWeek: 1, start: "13:00", end: "14:00"),
        ]
        XCTAssertEqual(
            Summary.summarizeWorkingHours(rules),
            "Mon, 9:00 to 10:00, 11:00 to 12:00 and 13:00 to 14:00"
        )
    }

    /// ⛔ A RULE SCOPED TO ONE EVENT TYPE IS NOT PART OF THE WORKING WEEK. Including it
    /// would report hours the booking page as a whole does not offer.
    func testAnEventTypeScopedRuleIsExcluded() throws {
        let rules = try [
            SchedulingFixture.rule(id: "r1", eventTypeId: "et1", dayOfWeek: 1, start: "09:00", end: "17:00"),
        ]
        XCTAssertNil(Summary.summarizeWorkingHours(rules))
    }

    /// ⚠️ THE WIRE IS SUNDAY-FIRST AND THE DISPLAY IS MONDAY-FIRST. `day_of_week: 0` is
    /// Sunday and must render last, not first.
    func testSundayIsWireZeroAndRendersLast() throws {
        let rules = try [
            SchedulingFixture.rule(id: "r0", dayOfWeek: 0, start: "10:00", end: "12:00"),
            SchedulingFixture.rule(id: "r1", dayOfWeek: 1, start: "09:00", end: "17:00"),
        ]
        XCTAssertEqual(
            Summary.summarizeWorkingHours(rules),
            "Mon, 9:00 to 17:00; Sun, 10:00 to 12:00"
        )
    }

    /// ⛔ nil RATHER THAN AN EMPTY STRING, because the caller draws a "Set your hours"
    /// link for nil and an empty row for "".
    func testNoRulesAtAllIsNil() {
        XCTAssertNil(Summary.summarizeWorkingHours([]))
    }

    /// ⛔ A CORRUPT `day_of_week` IS **FOLDED** HERE AND **SKIPPED** BY
    /// ``SchedulingHoursFormat/weekFromRules(_:)``, AND THE TWO DISAGREEING IS THE
    /// SOURCE'S BEHAVIOUR RATHER THAN A PORT DEFECT. This function's guard runs AFTER the
    /// modulo has already folded every integer into 0...6, so it can never fire: `9`
    /// becomes Tuesday. The grid's guard runs BEFORE, on the wire value, so `9` is
    /// dropped. Both are the web client's formatters, ported verbatim.
    ///
    /// ⚠️ THIS TEST ASSERTED THE TIDY ANSWER FIRST AND FAILED, WHICH IS WHY IT IS WORTH
    /// HAVING. `nil` is what the careful-looking implementation would return, and matching
    /// it would have made the register disagree with the browser on a corrupt row. The
    /// dead guard is left in place because removing it would suggest the check had been
    /// considered and rejected, when what is true is that it is inherited.
    func testADayOutsideTheWeekIsFoldedHereAndSkippedInTheGrid() throws {
        let rules = try [SchedulingFixture.rule(dayOfWeek: 9, start: "09:00", end: "17:00")]
        XCTAssertEqual(Summary.summarizeWorkingHours(rules), "Tue, 9:00 to 17:00")
        XCTAssertTrue(SchedulingHoursFormat.weekFromRules(rules).allSatisfy(\.isEmpty))
    }

    // MARK: - Event types

    /// ⛔ ABSENT COUNTS AS TRUE. A row whose flags the server did not send is bookable.
    func testAbsentFlagsCountAsBookable() throws {
        let items = try [SchedulingFixture.eventType(slug: "intro", name: "Intro")]
        XCTAssertEqual(Summary.bookableEventTypes(items).map(\.slug), ["intro"])
    }

    func testAnInactiveOrPrivateEventTypeIsNotBookable() throws {
        let items = try [
            SchedulingFixture.eventType(id: "a", slug: "off", name: "Off", isActive: false),
            SchedulingFixture.eventType(id: "b", slug: "hidden", name: "Hidden", isPublic: false),
            SchedulingFixture.eventType(id: "c", slug: "live", name: "Live", isActive: true, isPublic: true),
        ]
        XCTAssertEqual(Summary.bookableEventTypes(items).map(\.slug), ["live"])
    }

    /// ⚠️ THE COUNT PLURALISES AND THE WORD `active` DOES NOT. That asymmetry is the
    /// web's and is preserved on purpose.
    func testTheSummaryPluralisesTheCountButNeverTheWordActive() throws {
        let one = try [SchedulingFixture.eventType(slug: "a", name: "A")]
        XCTAssertEqual(Summary.summarizeEventTypes(one), "1 event type, 1 active")

        let three = try [
            SchedulingFixture.eventType(id: "a", slug: "a", name: "A"),
            SchedulingFixture.eventType(id: "b", slug: "b", name: "B"),
            SchedulingFixture.eventType(id: "c", slug: "c", name: "C", isActive: false),
        ]
        XCTAssertEqual(Summary.summarizeEventTypes(three), "3 event types, 2 active")
    }

    /// ⛔ `active` COUNTS `isActive` ALONE AND IS NOT BOOKABILITY. A row that is active but
    /// not public still counts, because the register reports the switch the operator threw.
    func testActiveCountsTheSwitchAndNotBookability() throws {
        let items = try [
            SchedulingFixture.eventType(slug: "a", name: "A", isActive: true, isPublic: false),
        ]
        XCTAssertEqual(Summary.summarizeEventTypes(items), "1 event type, 1 active")
        XCTAssertTrue(Summary.bookableEventTypes(items).isEmpty)
    }

    func testNoEventTypesIsNil() {
        XCTAssertNil(Summary.summarizeEventTypes([]))
    }

    // MARK: - bookingUrlFor

    func testTheBookingUrlEncodesTheSlugAndLeavesTheHostAlone() {
        XCTAssertEqual(
            Summary.bookingUrlFor(publicHost: "acme.example.com", slug: "intro-call"),
            "https://acme.example.com/book/intro-call"
        )
    }

    /// ⛔ THE SLUG IS CUSTOMER-AUTHORED, SO A `/` IN IT MUST NOT REACH A DIFFERENT PATH.
    /// This is the assertion that rules out `urlPathAllowed`, which permits one.
    func testASlashInTheSlugIsEncodedRatherThanTraversing() {
        XCTAssertEqual(
            Summary.bookingUrlFor(publicHost: "acme.example.com", slug: "a/b"),
            "https://acme.example.com/book/a%2Fb"
        )
    }

    func testASpaceInTheSlugIsEncoded() {
        XCTAssertEqual(
            Summary.bookingUrlFor(publicHost: "h", slug: "a b"),
            "https://h/book/a%20b"
        )
    }

    /// ⛔ A NON-ASCII LETTER IS ENCODED AS ITS UTF-8 BYTES, AS `encodeURIComponent` DOES.
    /// `CharacterSet.alphanumerics` counts every Unicode letter as safe, which left
    /// `café` unencoded here while the browser sent `caf%C3%A9` for the same page.
    func testANonAsciiSlugIsEncodedByteForByteLikeTheBrowser() {
        XCTAssertEqual(
            Summary.bookingUrlFor(publicHost: "h", slug: "caf\u{E9}-\u{1F4C5}"),
            "https://h/book/caf%C3%A9-%F0%9F%93%85"
        )
    }

    /// The whole surviving set passes through untouched, and the reserved characters a
    /// slug could use to leave its path segment or start a query do not.
    func testTheUnreservedSetSurvivesAndTheReservedOnesAreEncoded() {
        XCTAssertEqual(
            Summary.bookingUrlFor(publicHost: "h", slug: "Az09-_.!~*'()"),
            "https://h/book/Az09-_.!~*'()"
        )
        XCTAssertEqual(
            Summary.bookingUrlFor(publicHost: "h", slug: "?#&=+%"),
            "https://h/book/%3F%23%26%3D%2B%25"
        )
    }

    // MARK: - bookingWhen

    private func now() throws -> Date {
        try XCTUnwrap(WireInstant.parse("2026-09-12T12:00:00Z"))
    }

    func testTodayAndTomorrowAreNamedAndAnythingElseIsDated() throws {
        let today = try now()
        XCTAssertEqual(
            Summary.bookingWhen(startAt: "2026-09-12T14:30:00Z", timezone: "UTC", now: today),
            "Today 14:30"
        )
        XCTAssertEqual(
            Summary.bookingWhen(startAt: "2026-09-13T10:00:00Z", timezone: "UTC", now: today),
            "Tomorrow 10:00"
        )
        XCTAssertEqual(
            Summary.bookingWhen(startAt: "2026-09-20T10:00:00Z", timezone: "UTC", now: today),
            "Sep 20, 10:00"
        )
    }

    /// ⛔ TODAY IS DECIDED IN THE OPERATOR'S ZONE. The same instant is "Today" in Toronto
    /// and "Tomorrow" in Tokyo, and getting this wrong is the bug the whole clock exists
    /// to avoid.
    func testTodayIsDecidedInTheOperatorsZoneAndNotInUTC() throws {
        let today = try now()
        XCTAssertEqual(
            Summary.bookingWhen(startAt: "2026-09-12T23:00:00Z", timezone: "America/Toronto", now: today),
            "Today 19:00"
        )
        XCTAssertEqual(
            Summary.bookingWhen(startAt: "2026-09-12T23:00:00Z", timezone: "Asia/Tokyo", now: today),
            "Tomorrow 8:00"
        )
    }

    /// ⚠️ UNPADDED HOUR, PADDED MINUTE — the register's shape.
    func testTheHourIsUnpaddedAndTheMinuteIsPadded() throws {
        XCTAssertEqual(
            try Summary.bookingWhen(startAt: "2026-09-12T09:05:00Z", timezone: "UTC", now: now()),
            "Today 9:05"
        )
    }

    /// ⚠️ THERE IS NO "Yesterday". A past booking falls through to the absolute form.
    func testAPastBookingFallsThroughToTheAbsoluteForm() throws {
        XCTAssertEqual(
            try Summary.bookingWhen(startAt: "2026-09-11T10:00:00Z", timezone: "UTC", now: now()),
            "Sep 11, 10:00"
        )
    }

    func testAnUnparseableStampIsNil() throws {
        XCTAssertNil(try Summary.bookingWhen(startAt: "soon", timezone: "UTC", now: now()))
    }

    // MARK: - bookingWho

    func testTheAttendeeNameWinsThenTheEmailThenSomeone() throws {
        let named = try SchedulingFixture.booking(attendees: #"[{"name":"Ada","email":"a@b.com"}]"#)
        XCTAssertEqual(Summary.bookingWho(named), "Ada")

        let emailed = try SchedulingFixture.booking(attendees: #"[{"email":"a@b.com"}]"#)
        XCTAssertEqual(Summary.bookingWho(emailed), "a@b.com")

        let anonymous = try SchedulingFixture.booking(attendees: "[]")
        XCTAssertEqual(Summary.bookingWho(anonymous), "Someone")

        let absent = try SchedulingFixture.booking()
        XCTAssertEqual(Summary.bookingWho(absent), "Someone")
    }

    /// ⚠️ A BLANK-AFTER-TRIM NAME FALLS THROUGH TO THE EMAIL. This is the JavaScript `||`
    /// and it is the reason a `??` port would be wrong.
    func testAWhitespaceNameFallsThroughToTheEmail() throws {
        let booking = try SchedulingFixture.booking(attendees: #"[{"name":"   ","email":"a@b.com"}]"#)
        XCTAssertEqual(Summary.bookingWho(booking), "a@b.com")
    }

    // MARK: - bookingEventTypeName

    func testTheEventTypeNameResolvesThroughTheSlug() throws {
        let types = try [SchedulingFixture.eventType(slug: "intro", name: "Intro call")]
        let booking = try SchedulingFixture.booking(slug: "intro")
        XCTAssertEqual(Summary.bookingEventTypeName(booking, eventTypes: types), "Intro call")
    }

    /// ⚠️ AN UNRESOLVED SLUG IS SHOWN RAW. The event type may have been deleted since, and
    /// the slug is the only true thing left to say about it.
    func testAnUnresolvedSlugIsShownRaw() throws {
        let booking = try SchedulingFixture.booking(slug: "gone")
        XCTAssertEqual(Summary.bookingEventTypeName(booking, eventTypes: []), "gone")
    }

    /// ⚠️ `Booking` IS RESERVED FOR A ROW THAT NAMES NO EVENT TYPE AT ALL, absent or empty.
    func testNoSlugAtAllIsTheWordBooking() throws {
        let absent = try SchedulingFixture.booking()
        XCTAssertEqual(Summary.bookingEventTypeName(absent, eventTypes: []), "Booking")

        let empty = try SchedulingFixture.booking(slug: "")
        XCTAssertEqual(Summary.bookingEventTypeName(empty, eventTypes: []), "Booking")
    }
}
