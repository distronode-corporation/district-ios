import DistrictData
import DistrictModel
import Foundation
import XCTest

/// The working-hours grid and the date-overrides table.
final class SchedulingHoursFormatTests: XCTestCase {
    private typealias Hours = SchedulingHoursFormat

    // MARK: - Day mapping

    /// ⚠️ THE TWO CONVERSIONS ARE INVERSES ACROSS THE WHOLE WEEK, which is the only thing
    /// that stops the grid and the wire drifting by a day.
    func testTheDayConversionsAreInverses() {
        for display in 0 ... 6 {
            XCTAssertEqual(Hours.displayDay(Hours.wireDay(display)), display)
        }
        for wire in 0 ... 6 {
            XCTAssertEqual(Hours.wireDay(Hours.displayDay(wire)), wire)
        }
    }

    /// ⛔ MONDAY IS DISPLAY 0 AND WIRE 1; SUNDAY IS DISPLAY 6 AND WIRE 0.
    func testMondayIsDisplayZeroAndSundayIsWireZero() {
        XCTAssertEqual(Hours.wireDay(0), 1)
        XCTAssertEqual(Hours.wireDay(6), 0)
        XCTAssertEqual(Hours.displayDay(0), 6)
        XCTAssertEqual(Hours.displayDay(1), 0)
    }

    /// ⚠️ WRITTEN TOTAL FOR NEGATIVES, so a caller cannot produce an array index of -1 —
    /// which in Swift is a crash rather than the `undefined` the source would give.
    func testTheConversionsAreTotalForNegatives() {
        XCTAssertTrue((0 ... 6).contains(Hours.wireDay(-1)))
        XCTAssertTrue((0 ... 6).contains(Hours.displayDay(-1)))
    }

    func testTheWeekDayNamesAreMondayFirst() {
        XCTAssertEqual(Hours.weekDayNames.first, "Monday")
        XCTAssertEqual(Hours.weekDayNames.last, "Sunday")
        XCTAssertEqual(Hours.weekDayNames.count, 7)
    }

    // MARK: - weekFromRules

    func testTheWeekIsSevenDaysMondayFirstSortedByStart() throws {
        let rules = try [
            SchedulingFixture.rule(id: "b", dayOfWeek: 1, start: "13:00", end: "17:00"),
            SchedulingFixture.rule(id: "a", dayOfWeek: 1, start: "09:00", end: "12:00"),
            SchedulingFixture.rule(id: "c", dayOfWeek: 0, start: "10:00", end: "11:00"),
        ]
        let week = Hours.weekFromRules(rules)
        XCTAssertEqual(week.count, 7)
        XCTAssertEqual(week[0].map(\.start), ["09:00", "13:00"])
        XCTAssertEqual(week[0].map(\.ruleId), ["a", "b"])
        XCTAssertEqual(week[6].map(\.start), ["10:00"])
    }

    /// ⛔ AN EVENT-TYPE-SCOPED RULE IS NOT PART OF THE WORKING WEEK, so the grid must not
    /// draw it — an edit there would silently rewrite one event type's availability.
    func testAnEventTypeScopedRuleIsNotInTheGrid() throws {
        let rules = try [
            SchedulingFixture.rule(eventTypeId: "et1", dayOfWeek: 1, start: "09:00", end: "17:00"),
        ]
        XCTAssertTrue(Hours.weekFromRules(rules).allSatisfy(\.isEmpty))
    }

    /// ⛔ THE RANGE CHECK IS ON THE **WIRE** VALUE, so `9` is dropped here. See the ⛔ in
    /// `SchedulingOverviewSummaryTests` for why the register disagrees.
    func testACorruptDayIsDroppedFromTheGrid() throws {
        let rules = try [SchedulingFixture.rule(dayOfWeek: 9, start: "09:00", end: "17:00")]
        XCTAssertTrue(Hours.weekFromRules(rules).allSatisfy(\.isEmpty))
    }

    /// ⚠️ THE RULE ID SURVIVES INTO THE GRID even though nothing read-only needs it; the
    /// write stage diffs by id and would otherwise have to re-read.
    func testTheRangeCarriesItsRuleId() throws {
        let rules = try [SchedulingFixture.rule(id: "rule_7", dayOfWeek: 3, start: "08:00", end: "09:00")]
        XCTAssertEqual(Hours.weekFromRules(rules)[2].first?.ruleId, "rule_7")
    }

    // MARK: - formatOverrideDate

    func testAnIsoDateBecomesAReadableOne() {
        XCTAssertEqual(Hours.formatOverrideDate("2026-09-12"), "Sep 12, 2026")
        XCTAssertEqual(Hours.formatOverrideDate("2026-01-01"), "Jan 1, 2026")
    }

    /// ⛔ FORMATTED FROM THE STRING AND NEVER THROUGH A `Date`, so it cannot land a day
    /// early for anybody west of UTC. A parse-and-reformat implementation renders
    /// "Sep 11" here on a Toronto machine.
    func testTheDateIsNotShiftedByTheDeviceZone() {
        XCTAssertEqual(Hours.formatOverrideDate("2026-09-12"), "Sep 12, 2026")
    }

    /// ⚠️ ANYTHING MALFORMED COMES BACK UNCHANGED; it is still the truth about the row.
    func testAMalformedDateIsReturnedUnchanged() {
        XCTAssertEqual(Hours.formatOverrideDate("2026-13-01"), "2026-13-01")
        XCTAssertEqual(Hours.formatOverrideDate("not-a-date"), "not-a-date")
        XCTAssertEqual(Hours.formatOverrideDate(""), "")
        XCTAssertEqual(Hours.formatOverrideDate("26-09-12"), "26-09-12")
    }

    // MARK: - formatOverrideDates

    func testOneDaySaysItOnce() {
        XCTAssertEqual(
            Hours.formatOverrideDates(start: "2026-09-12", end: "2026-09-12"),
            "Sep 12, 2026"
        )
    }

    /// ⚠️ A SPAN INSIDE ONE YEAR SAYS THE YEAR ONCE, AT THE END.
    func testASpanInOneYearSaysTheYearOnce() {
        XCTAssertEqual(
            Hours.formatOverrideDates(start: "2026-09-12", end: "2026-09-14"),
            "Sep 12 to Sep 14, 2026"
        )
    }

    /// ⚠️ A SPAN ACROSS NEW YEAR SAYS IT TWICE, because it has to.
    func testASpanAcrossNewYearSaysBothYears() {
        XCTAssertEqual(
            Hours.formatOverrideDates(start: "2026-12-30", end: "2027-01-02"),
            "Dec 30, 2026 to Jan 2, 2027"
        )
    }

    /// ⚠️ THE YEAR IS STRIPPED ONLY IF IT IS THERE. A malformed start has no `, YYYY`
    /// tail, so the strip must not assume the shape it just asked for.
    func testAMalformedStartInASpanIsNotMangled() {
        XCTAssertEqual(
            Hours.formatOverrideDates(start: "2026-99-12", end: "2026-09-14"),
            "2026-99-12 to Sep 14, 2026"
        )
    }

    // MARK: - overrideHours

    private func row(
        isAvailable: Bool,
        reason: String,
        start: String? = nil,
        end: String? = nil
    ) -> SchedulingOverrideRow {
        SchedulingOverrideRow(
            key: "id:o1",
            kind: .single,
            target: "o1",
            start: "2026-09-12",
            end: "2026-09-12",
            days: 1,
            isAvailable: isAvailable,
            reason: reason,
            startTime: start,
            endTime: end
        )
    }

    func testCustomHoursRenderUnpadded() {
        XCTAssertEqual(
            Hours.overrideHours(row(isAvailable: true, reason: "custom_hours", start: "09:00", end: "12:00")),
            "9:00 to 12:00"
        )
    }

    /// ⚠️ THE TWO UNAVAILABLE WORDINGS ARE CHOSEN BY THE STORED `reason`.
    func testOutOfOfficeAndUnavailableAreDifferentReasons() {
        XCTAssertEqual(Hours.overrideHours(row(isAvailable: false, reason: "out_of_office")), "Out of office")
        XCTAssertEqual(Hours.overrideHours(row(isAvailable: false, reason: "day_off")), "Unavailable")
        XCTAssertEqual(Hours.overrideHours(row(isAvailable: false, reason: "")), "Unavailable")
    }

    /// ⚠️ AVAILABLE WITH NO HOURS IS STILL "Unavailable" rather than a blank cell.
    func testAnAvailableRowWithNoHoursFallsBack() {
        XCTAssertEqual(Hours.overrideHours(row(isAvailable: true, reason: "day_off")), "Unavailable")
    }

    // MARK: - todayInZone

    func testTodayIsPaddedAndZoned() throws {
        let instant = try XCTUnwrap(WireInstant.parse("2026-09-12T02:30:00Z"))
        XCTAssertEqual(Hours.todayInZone("UTC", now: instant), "2026-09-12")
        XCTAssertEqual(Hours.todayInZone("America/Toronto", now: instant), "2026-09-11")
    }

    // MARK: - upcomingOverrides

    func testSingleDaysBecomeSingleRows() throws {
        let overrides = try [
            SchedulingFixture.override(id: "o1", date: "2026-09-14"),
            SchedulingFixture.override(id: "o2", date: "2026-09-12"),
        ]
        let rows = Hours.upcomingOverrides(overrides, today: "2026-09-01")
        XCTAssertEqual(rows.map(\.start), ["2026-09-12", "2026-09-14"])
        XCTAssertEqual(rows.map(\.key), ["id:o2", "id:o1"])
        XCTAssertTrue(rows.allSatisfy { $0.kind == .single && $0.days == 1 })
    }

    /// ⛔ A SPAN IS ONE ROW PER DAY ON THE WIRE AND MUST FOLD INTO ONE ROW ON SCREEN,
    /// or a fortnight off is fourteen table rows.
    func testAGroupFoldsIntoOneRowWithItsEndsWidened() throws {
        let overrides = try [
            SchedulingFixture.override(id: "o2", date: "2026-09-13", groupId: "g1"),
            SchedulingFixture.override(id: "o1", date: "2026-09-12", groupId: "g1"),
            SchedulingFixture.override(id: "o3", date: "2026-09-14", groupId: "g1"),
        ]
        let rows = Hours.upcomingOverrides(overrides, today: "2026-09-01")
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.kind, .group)
        XCTAssertEqual(row.target, "g1")
        XCTAssertEqual(row.key, "group:g1")
        XCTAssertEqual([row.start, row.end], ["2026-09-12", "2026-09-14"])
        XCTAssertEqual(row.days, 3)
    }

    /// ⛔ THE GROUP'S REASON COMES FROM THE **FIRST** ROW SEEN and later rows only widen
    /// the ends. Asserted because it is the source's behaviour rather than a chosen one.
    func testAGroupTakesItsReasonFromTheFirstRowSeen() throws {
        let overrides = try [
            SchedulingFixture.override(id: "o1", date: "2026-09-13", reason: "out_of_office", groupId: "g1"),
            SchedulingFixture.override(id: "o2", date: "2026-09-12", reason: "day_off", groupId: "g1"),
        ]
        let row = try XCTUnwrap(Hours.upcomingOverrides(overrides, today: "2026-09-01").first)
        XCTAssertEqual(row.reason, "out_of_office")
        XCTAssertEqual(row.start, "2026-09-12")
    }

    /// ⚠️ `days` COUNTS ROWS, NOT CALENDAR SPAN. A group with a gap reports what was
    /// stored, which is the truth about the data.
    func testDaysCountsRowsAndNotTheCalendarSpan() throws {
        let overrides = try [
            SchedulingFixture.override(id: "o1", date: "2026-09-12", groupId: "g1"),
            SchedulingFixture.override(id: "o2", date: "2026-09-20", groupId: "g1"),
        ]
        let row = try XCTUnwrap(Hours.upcomingOverrides(overrides, today: "2026-09-01").first)
        XCTAssertEqual(row.days, 2)
        XCTAssertEqual([row.start, row.end], ["2026-09-12", "2026-09-20"])
    }

    /// ⚠️ THE FILTER IS ON `end`, so somebody four days into a fortnight off still sees it.
    func testASpanThatStartedInThePastButEndsLaterIsKept() throws {
        let overrides = try [
            SchedulingFixture.override(id: "o1", date: "2026-09-01", groupId: "g1"),
            SchedulingFixture.override(id: "o2", date: "2026-09-20", groupId: "g1"),
        ]
        XCTAssertEqual(Hours.upcomingOverrides(overrides, today: "2026-09-12").count, 1)
    }

    func testAFinishedOverrideIsDropped() throws {
        let overrides = try [SchedulingFixture.override(id: "o1", date: "2026-09-01")]
        XCTAssertTrue(Hours.upcomingOverrides(overrides, today: "2026-09-12").isEmpty)
    }

    /// ⚠️ TODAY ITSELF IS KEPT — the comparison is `>=`, because a day off today is very
    /// much still relevant.
    func testTodayItselfIsKept() throws {
        let overrides = try [SchedulingFixture.override(id: "o1", date: "2026-09-12")]
        XCTAssertEqual(Hours.upcomingOverrides(overrides, today: "2026-09-12").count, 1)
    }

    /// ⚠️ AN EMPTY `group_id` IS TREATED AS ABSENT, matching the source's falsy test.
    func testAnEmptyGroupIdIsTreatedAsASingleDay() throws {
        let overrides = try [SchedulingFixture.override(id: "o1", date: "2026-09-12", groupId: "")]
        XCTAssertEqual(Hours.upcomingOverrides(overrides, today: "2026-09-01").first?.kind, .single)
    }

    /// ⛔ TWO OVERRIDES ON THE SAME DATE KEEP THE FORK'S OWN ORDER. Swift's sort is not
    /// stable and JavaScript's is, so without the index tiebreak these two could swap
    /// between runs — an intermittent difference from the browser.
    func testTiedStartsKeepTheirIncomingOrder() throws {
        let overrides = try (1 ... 8).map {
            try SchedulingFixture.override(id: "o\($0)", date: "2026-09-12", reason: "r\($0)")
        }
        let rows = Hours.upcomingOverrides(overrides, today: "2026-09-01")
        XCTAssertEqual(rows.map(\.reason), (1 ... 8).map { "r\($0)" })
    }

    func testNoOverridesIsAnEmptyTable() {
        XCTAssertTrue(Hours.upcomingOverrides([], today: "2026-09-12").isEmpty)
    }
}
