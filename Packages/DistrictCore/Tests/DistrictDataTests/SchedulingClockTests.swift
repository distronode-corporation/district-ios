import DistrictData
import DistrictModel
import Foundation
import XCTest

/// The one clock every scheduling surface formats through.
///
/// ⛔ THE ZONE IS THE OPERATOR'S PROFILE AND NEVER THE DEVICE'S, WHICH IS WHAT MOST OF
/// THIS FILE IS ABOUT. These assertions pass on a machine set to any timezone precisely
/// because every one of them names the zone explicitly; a regression that reached for
/// `Date.formatted` would pass on a Toronto laptop and fail in CI, or worse, pass in both
/// and be wrong for a travelling operator.
final class SchedulingClockTests: XCTestCase {
    /// The whole reason this type exists: one instant, two zones, two different days.
    func testTheSameInstantIsADifferentDayInTwoZones() throws {
        let instant = try XCTUnwrap(WireInstant.parse("2026-09-12T02:30:00Z"))
        let toronto = SchedulingClock.parts(of: instant, timezone: "America/Toronto")
        let tokyo = SchedulingClock.parts(of: instant, timezone: "Asia/Tokyo")
        XCTAssertEqual([toronto.day, toronto.hour], [11, 22])
        XCTAssertEqual([tokyo.day, tokyo.hour], [12, 11])
    }

    /// ⚠️ AN UNKNOWN ZONE FALLS BACK TO UTC RATHER THAN REFUSING, so a profile carrying a
    /// zone this platform's database lacks still renders its bookings.
    func testAnUnknownZoneFallsBackToUTC() throws {
        let instant = try XCTUnwrap(WireInstant.parse("2026-09-12T02:30:00Z"))
        let unknown = SchedulingClock.parts(of: instant, timezone: "Mars/Olympus_Mons")
        XCTAssertEqual([unknown.day, unknown.hour], [12, 2])
    }

    /// ⛔ MIDNIGHT IS `0`, NEVER `24` — the property the TypeScript's `% 24` exists to
    /// guarantee and that `Calendar` gives for free.
    func testMidnightIsZeroAndNotTwentyFour() throws {
        let instant = try XCTUnwrap(WireInstant.parse("2026-09-12T00:00:00Z"))
        XCTAssertEqual(SchedulingClock.parts(of: instant, timezone: "UTC").hour, 0)
    }

    /// ⛔ THE TWO CLOCK SHAPES ARE DIFFERENT AND BOTH ARE DELIBERATE. Pinned together so a
    /// tidy-up that unified them fails here rather than on one screen.
    func testTheUnpaddedAndPaddedClocksDisagreeOnPurpose() {
        let parts = SchedulingZonedParts(year: 2026, month: 9, day: 12, hour: 9, minute: 5)
        XCTAssertEqual(SchedulingClock.clock(parts), "9:05")
        XCTAssertEqual(SchedulingClock.paddedClock(parts), "09:05")
    }

    func testMonthNamesAreOneBasedAndBounded() {
        XCTAssertEqual(SchedulingClock.monthName(1), "Jan")
        XCTAssertEqual(SchedulingClock.monthName(12), "Dec")
        XCTAssertNil(SchedulingClock.monthName(0))
        XCTAssertNil(SchedulingClock.monthName(13))
    }

    func testPaddingIsTwoDigitsAndLeavesLargerNumbersAlone() {
        XCTAssertEqual(SchedulingClock.paddedTwo(0), "00")
        XCTAssertEqual(SchedulingClock.paddedTwo(9), "09")
        XCTAssertEqual(SchedulingClock.paddedTwo(10), "10")
        XCTAssertEqual(SchedulingClock.paddedTwo(-1), "-1")
    }

    /// ⛔ CALENDAR DAYS, NOT ELAPSED TIME, WHICH IS THE WHOLE ARGUMENT FOR `dayDelta`.
    /// Twenty-three hours apart is ONE day when it crosses midnight, and an elapsed-time
    /// subtraction would answer zero.
    func testDayDeltaCountsMidnightsAndNotHours() {
        let late = SchedulingZonedParts(year: 2026, month: 9, day: 12, hour: 23, minute: 30)
        let early = SchedulingZonedParts(year: 2026, month: 9, day: 13, hour: 22, minute: 30)
        XCTAssertEqual(SchedulingClock.dayDelta(from: late, to: early), 1)
    }

    func testDayDeltaCrossesMonthsAndYearsAndGoesNegative() {
        let endOfYear = SchedulingZonedParts(year: 2026, month: 12, day: 31, hour: 0, minute: 0)
        let newYear = SchedulingZonedParts(year: 2027, month: 1, day: 1, hour: 0, minute: 0)
        XCTAssertEqual(SchedulingClock.dayDelta(from: endOfYear, to: newYear), 1)
        XCTAssertEqual(SchedulingClock.dayDelta(from: newYear, to: endOfYear), -1)
    }

    /// ⚠️ THE SUBTRACTION IS DONE IN UTC OVER ALREADY-ZONED FIELDS, so a day on which the
    /// clocks change is still one day rather than 0.958 of one rounded.
    func testADaylightSavingBoundaryIsStillOneDay() {
        let before = SchedulingZonedParts(year: 2026, month: 3, day: 8, hour: 0, minute: 0)
        let after = SchedulingZonedParts(year: 2026, month: 3, day: 9, hour: 0, minute: 0)
        XCTAssertEqual(SchedulingClock.dayDelta(from: before, to: after), 1)
    }

    /// ⚠️ A YEAR NO CALENDAR CAN HOLD IS nil ON EITHER SIDE, rather than a number
    /// computed from a date that wrapped. Hostile input: the fields are public and
    /// nothing stops a caller building them.
    func testAYearNoCalendarCanHoldHasNoDayDelta() {
        let normal = SchedulingZonedParts(year: 2026, month: 9, day: 12, hour: 0, minute: 0)
        let absurd = SchedulingZonedParts(year: 300_000_000_000, month: 1, day: 1, hour: 0, minute: 0)
        XCTAssertNil(SchedulingClock.dayDelta(from: absurd, to: normal))
        XCTAssertNil(SchedulingClock.dayDelta(from: normal, to: absurd))
    }

    // MARK: - displayTimezone

    /// ⚠️ AN EMPTY PROFILE ZONE IS UTC, AND A SET ONE IS PASSED THROUGH UNCHANGED, even
    /// one this platform cannot resolve, so the label names what the profile says.
    func testTheDisplayZoneFallsBackToUTCOnlyWhenEmpty() throws {
        XCTAssertEqual(try SchedulingFixture.me(timezone: "").displayTimezone, "UTC")
        XCTAssertEqual(try SchedulingFixture.me(timezone: "Asia/Tokyo").displayTimezone, "Asia/Tokyo")
        XCTAssertEqual(try SchedulingFixture.me(timezone: "Mars/Olympus").displayTimezone, "Mars/Olympus")
    }
}
