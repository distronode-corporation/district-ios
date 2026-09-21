@testable import DistrictAI
import DistrictData
import DistrictModel
import Foundation
import XCTest

/// The weekly working hours and the dated overrides.
@MainActor
final class SchedulingWritesAvailabilityTests: XCTestCase {
    // MARK: - The week model

    /// ⛔ MONDAY FIRST ON SCREEN, SUNDAY FIRST ON THE WIRE. A row index used as a
    /// `day_of_week` publishes somebody's Monday hours on Sunday.
    func testTheRowOrderAndTheWireOrderDisagreeByOneDay() {
        XCTAssertEqual(SchedulingWorkingHours.wireDay(forRow: 0), 1)
        XCTAssertEqual(SchedulingWorkingHours.wireDay(forRow: 6), 0)
        XCTAssertEqual(SchedulingWorkingHours.row(forWireDay: 0), 6)
        XCTAssertEqual(SchedulingWorkingHours.row(forWireDay: 1), 0)
    }

    /// ⛔ A RULE WITH AN `event_type_id` GOVERNS ONE EVENT TYPE AND IS NOT PART OF
    /// THE TENANCY'S WEEK. Folding it in would promote one event type's hours to
    /// everybody's on the first save.
    func testOnlyGlobalRulesReachTheEditor() {
        let week = SchedulingWorkingHours.week(from: [
            Self.rule(id: "r_1", day: 1, start: "09:00", end: "17:00"),
            Self.rule(id: "r_2", day: 1, start: "18:00", end: "19:00", eventTypeId: "et_1"),
        ])
        XCTAssertEqual(week[0].count, 1)
        XCTAssertEqual(week[0].first?.ruleId, "r_1")
    }

    func testASundayRuleLandsOnTheLastRow() {
        let week = SchedulingWorkingHours.week(from: [Self.rule(id: "r_1", day: 0)])
        XCTAssertEqual(week[6].count, 1)
        XCTAssertTrue(week[0].isEmpty)
    }

    /// ⚠️ FORMAT ONLY, AND NOT A CLOCK CHECK: the fork is the validator. What this
    /// catches is the shape refused for certain, a dropped leading zero.
    func testADroppedLeadingZeroIsRefused() {
        let errors = SchedulingWorkingHours.errors(in: [Self.range(start: "9:00", end: "17:00")])
        XCTAssertEqual(errors, ["Enter a time as HH:MM."])
    }

    func testAnEndBeforeItsStartIsRefused() {
        let errors = SchedulingWorkingHours.errors(in: [Self.range(start: "17:00", end: "09:00")])
        XCTAssertEqual(errors, ["The end has to be after the start."])
    }

    /// ⚠️ THE OVERLAP IS REPORTED ON THE LATER RANGE BY CLOCK ORDER, not on the
    /// later one by position: pointing at the window somebody already decided about
    /// is the less useful of the two.
    func testAnOverlapIsReportedOnTheLaterWindow() {
        let errors = SchedulingWorkingHours.errors(in: [
            Self.range(start: "13:00", end: "17:00"),
            Self.range(start: "09:00", end: "14:00"),
        ])
        XCTAssertNil(errors[1])
        XCTAssertEqual(errors[0], "These hours overlap another range on this day.")
    }

    func testWindowsThatMeetExactlyDoNotOverlap() {
        let errors = SchedulingWorkingHours.errors(in: [
            Self.range(start: "09:00", end: "12:00"),
            Self.range(start: "12:00", end: "17:00"),
        ])
        XCTAssertTrue(errors.allSatisfy { $0 == nil })
    }

    // MARK: - The diff

    /// ⛔ AN UNCHANGED WINDOW EMITS NOTHING. Re-sending it spends a write from the
    /// workspace's hourly budget to store what is already there.
    func testAnUntouchedWeekProducesNoWrites() {
        let stored = [Self.rule(id: "r_1", day: 1)]
        let diff = SchedulingWorkingHours.diff(
            week: SchedulingWorkingHours.week(from: stored),
            stored: stored
        )
        XCTAssertTrue(diff.isEmpty)
    }

    func testAChangedWindowIsAPatchAndNotADeleteAndCreate() {
        let stored = [Self.rule(id: "r_1", day: 1)]
        var week = SchedulingWorkingHours.week(from: stored)
        week[0][0].end = "18:00"
        let diff = SchedulingWorkingHours.diff(week: week, stored: stored)

        XCTAssertEqual(diff.patches, [
            SchedulingHoursPatch(id: "r_1", dayOfWeek: 1, start: "09:00", end: "18:00"),
        ])
        XCTAssertTrue(diff.deletes.isEmpty)
        XCTAssertTrue(diff.creates.isEmpty)
    }

    func testARemovedWindowIsADelete() {
        let stored = [Self.rule(id: "r_1", day: 1)]
        var week = SchedulingWorkingHours.week(from: stored)
        week[0] = []
        let diff = SchedulingWorkingHours.diff(week: week, stored: stored)

        XCTAssertEqual(diff.deletes, ["r_1"])
    }

    /// ⛔ A CREATE CARRIES NO `event_type_id`, which the fork reads as the global
    /// rule. Sending one would narrow the tenancy's week to one event type.
    func testANewWindowIsACreateOnTheRightDay() {
        var week = Array(repeating: [SchedulingHoursDraftRange](), count: 7)
        week[6] = [Self.range()]
        let diff = SchedulingWorkingHours.diff(week: week, stored: [])

        XCTAssertEqual(diff.creates, [
            SchedulingHoursCreate(dayOfWeek: 0, start: "09:00", end: "17:00"),
        ])
    }

    /// ⚠️ COPYING REUSES THE TARGET'S OWN RULE IDS POSITIONALLY, which is what
    /// turns "copy to all weekdays" into patches instead of a delete-and-recreate
    /// of the whole working week.
    func testCopyingToWeekdaysReusesTheTargetsRuleIds() {
        let stored = [
            Self.rule(id: "r_mon", day: 1, start: "08:00", end: "12:00"),
            Self.rule(id: "r_tue", day: 2, start: "10:00", end: "11:00"),
        ]
        let week = SchedulingWorkingHours.copyToWeekdays(
            from: 0,
            in: SchedulingWorkingHours.week(from: stored)
        )
        let diff = SchedulingWorkingHours.diff(week: week, stored: stored)

        XCTAssertTrue(diff.deletes.isEmpty)
        XCTAssertEqual(diff.patches.count, 1)
        XCTAssertEqual(diff.patches.first?.id, "r_tue")
        XCTAssertEqual(diff.patches.first?.start, "08:00")
        // Wednesday, Thursday and Friday had nothing to reuse.
        XCTAssertEqual(diff.creates.count, 3)
    }

    // MARK: - The rules save

    /// ⛔ DELETES, THEN PATCHES, THEN CREATES. The fork refuses overlapping
    /// windows, so a create issued before the delete it replaces is refused against
    /// a window on its way out.
    func testTheSaveRunsDeletesThenPatchesThenCreates() async {
        let stored = SchedulingWritesFixtures.items(
            """
            {"id":"r_1","event_type_id":null,"day_of_week":1,"start_time":"09:00","end_time":"17:00"},\
            {"id":"r_2","event_type_id":null,"day_of_week":2,"start_time":"09:00","end_time":"17:00"}
            """
        )
        let transport = SettingsTransport([
            stored,
            SchedulingWritesFixtures.noContent,
            Self.ruleBody,
            Self.ruleBody,
            stored,
        ])
        let model = Self.rules(transport)
        await model.load()
        model.removeRange(model.week[1][0].id, fromRow: 1)
        model.setEnd("18:00", for: model.week[0][0].id, inRow: 0)
        model.addRange(toRow: 3)
        await model.save()

        XCTAssertEqual(SchedulingWritesFixtures.calls(transport).map(\.op), [
            "availability.rules.list",
            "availability.rules.delete",
            "availability.rules.patch",
            "availability.rules.create",
            "availability.rules.list",
        ])
    }

    /// ⚠️ A SAVE WITH NOTHING TO SEND SPENDS NO REQUEST AT ALL.
    func testASaveWithNoChangesSendsNothingAndSaysSo() async {
        let transport = SettingsTransport([Self.rulesList])
        let model = Self.rules(transport)
        await model.load()
        await model.save()

        XCTAssertEqual(SchedulingWritesFixtures.calls(transport).count, 1)
        XCTAssertEqual(model.notice, "Nothing to save.")
    }

    /// ⛔ SAVE IS DISABLED WHILE A WINDOW IS INVALID, unlike the event-type
    /// editor's: this screen already shows which row is wrong.
    func testAnInvalidWindowDisablesTheSave() async {
        let transport = SettingsTransport([Self.rulesList])
        let model = Self.rules(transport)
        await model.load()
        model.setStart("9:00", for: model.week[0][0].id, inRow: 0)

        XCTAssertFalse(model.canSave)
        await model.save()
        XCTAssertEqual(SchedulingWritesFixtures.calls(transport).count, 1)
    }

    // MARK: - Overrides

    /// ⛔ A RANGE IS ONE ROW AND ONE DELETE. Offering fourteen deletes for a
    /// fortnight away is offering thirteen ways to half-cancel a holiday.
    ///
    /// ⚠️ DRIVEN THROUGH `load()` RATHER THAN THROUGH A STATIC, because the model holds
    /// no fold of its own: it calls ``SchedulingHoursFormat/upcomingOverrides(_:today:)``.
    /// The ALGORITHM is covered arm by arm in `DistrictDataTests`; what is covered here and nowhere else is the
    /// WIRING — that the model reaches that fold at all, that it hands it the `today`
    /// it was injected with rather than the device's, and that the row it produces is
    /// addressed by `kind` and `target` (which is what the delete switches on).
    ///
    /// ⚠️ THE FIXTURE CARRIES A FINISHED OVERRIDE ON PURPOSE. `o_0` ended eleven days
    /// before the injected `today`, so its absence is the only thing that proves the
    /// injected date reached the fold; a fixture of upcoming rows only would pass with
    /// `today` hardcoded to anything at all.
    func testARangeIsCollapsedIntoOneRow() async {
        let transport = SettingsTransport([Self.overridesMixedList])
        let model = Self.overrides(transport)
        await model.load()

        XCTAssertEqual(model.rows.count, 2, "the group is one row and the finished single is dropped")
        XCTAssertEqual(model.rows.first?.kind, .group)
        XCTAssertEqual(model.rows.first?.target, "g_1")
        XCTAssertEqual(model.rows.first?.days, 2)
        XCTAssertEqual(model.rows.last?.kind, .single)
        XCTAssertEqual(model.rows.last?.target, "o_3")
    }

    /// ⛔ `end_date` IS WHAT DECIDES WHICH SHAPE COMES BACK, so a one-day "range"
    /// must not send one: it would answer a group summary of a single day.
    func testAOneDayRangeIsSentAsASingleOverride() {
        var form = SchedulingOverrideForm()
        form.date = "2026-09-14"
        form.endDate = "2026-09-14"
        XCTAssertNil(form.draft()?.endDate)
    }

    func testAMultiDayRangeCarriesItsEndDate() {
        var form = SchedulingOverrideForm()
        form.date = "2026-09-14"
        form.endDate = "2026-09-18"
        XCTAssertEqual(form.draft()?.endDate, "2026-09-18")
        XCTAssertEqual(form.draft()?.reason, "day_off")
    }

    /// ⛔ CUSTOM HOURS ARE ONE DAY AND CARRY BOTH TIMES; the fork refuses a range
    /// of them, so a leftover end date is dropped rather than sent.
    func testCustomHoursDropALeftoverEndDate() {
        var form = SchedulingOverrideForm()
        form.date = "2026-09-14"
        form.endDate = "2026-09-18"
        form.reason = "custom_hours"
        let draft = form.draft()
        XCTAssertNil(draft?.endDate)
        XCTAssertEqual(draft?.startTime, "09:00")
        XCTAssertEqual(draft?.endTime, "17:00")
    }

    func testAnEndDateBeforeItsStartIsRefused() {
        var form = SchedulingOverrideForm()
        form.date = "2026-09-18"
        form.endDate = "2026-09-14"
        XCTAssertEqual(form.error, "The last day has to be on or after the first.")
    }

    func testAnEmptyDateIsRefused() {
        XCTAssertEqual(SchedulingOverrideForm().error, "Pick a date.")
    }

    /// ⛔ THE GROUP DELETE'S PARAM IS `groupId`, camelCase, ALONE IN THIS FAMILY.
    /// Every other key the scheduler ops take is snake_case; `group_id` is a 400.
    func testDeletingAWholeRangeSendsCamelCaseGroupId() async {
        let transport = SettingsTransport([
            Self.overridesList,
            SchedulingWritesFixtures.noContent,
            SchedulingWritesFixtures.ok(#"{"items":[]}"#),
        ])
        let model = Self.overrides(transport)
        await model.load()
        guard let row = model.rows.first else {
            return XCTFail("the fixture has one row")
        }
        model.beginDelete(row)
        await model.delete()

        let call = SchedulingWritesFixtures.calls(transport)[1]
        XCTAssertEqual(call.op, "availability.overrides.deleteGroup")
        XCTAssertEqual(call.params["groupId"] as? String, "g_1")
        XCTAssertNil(call.params["group_id"])
    }

    /// ⚠️ THE SENTENCE NAMES THE NUMBER OF DAYS, because that is what somebody is
    /// agreeing to lose.
    func testTheRangeConfirmationNamesTheNumberOfDays() async {
        let transport = SettingsTransport([Self.overridesList])
        let model = Self.overrides(transport)
        await model.load()
        guard let row = model.rows.first else {
            return XCTFail("the fixture has one row")
        }
        XCTAssertEqual(model.deleteBody(for: row), "All 2 days go back to your weekly hours.")
    }

    // MARK: - Fixtures

    private static let ruleBody = SchedulingWritesFixtures.ok(
        #"{"id":"r_1","event_type_id":null,"day_of_week":1,"start_time":"09:00","end_time":"17:00"}"#
    )

    private static let rulesList = SchedulingWritesFixtures.items(
        #"{"id":"r_1","event_type_id":null,"day_of_week":1,"start_time":"09:00","end_time":"17:00"}"#
    )

    /// ⚠️ `o_0` IS ALREADY OVER at the injected `today` of 2026-09-12; see the ⚠️ on
    /// ``testARangeIsCollapsedIntoOneRow``.
    private static let overridesMixedList = SchedulingWritesFixtures.items(
        """
        {"id":"o_0","date":"2026-09-01","is_available":false,"reason":"day_off",\
        "start_time":null,"end_time":null,"group_id":null},\
        {"id":"o_1","date":"2026-09-14","is_available":false,"reason":"day_off",\
        "start_time":null,"end_time":null,"group_id":"g_1"},\
        {"id":"o_2","date":"2026-09-15","is_available":false,"reason":"day_off",\
        "start_time":null,"end_time":null,"group_id":"g_1"},\
        {"id":"o_3","date":"2026-09-20","is_available":false,"reason":"day_off",\
        "start_time":null,"end_time":null,"group_id":null}
        """
    )

    private static let overridesList = SchedulingWritesFixtures.items(
        """
        {"id":"o_1","date":"2026-09-14","is_available":false,"reason":"day_off",\
        "start_time":null,"end_time":null,"group_id":"g_1"},\
        {"id":"o_2","date":"2026-09-15","is_available":false,"reason":"day_off",\
        "start_time":null,"end_time":null,"group_id":"g_1"}
        """
    )

    private static func rules(_ transport: SettingsTransport) -> SchedulingAvailabilityRulesModel {
        SchedulingAvailabilityRulesModel(
            admin: SchedulingWritesFixtures.repository(transport),
            workspaceId: "ws_1",
            onSaved: { _ in }
        )
    }

    private static func overrides(_ transport: SettingsTransport) -> SchedulingAvailabilityOverridesModel {
        SchedulingAvailabilityOverridesModel(
            admin: SchedulingWritesFixtures.repository(transport),
            workspaceId: "ws_1",
            today: "2026-09-12",
            onSaved: { _ in }
        )
    }

    private static func range(start: String = "09:00", end: String = "17:00") -> SchedulingHoursDraftRange {
        SchedulingHoursDraftRange(ruleId: nil, start: start, end: end)
    }

    private static func rule(
        id: String,
        day: Int,
        start: String = "09:00",
        end: String = "17:00",
        eventTypeId: String? = nil
    ) -> SchedulingAvailabilityRule {
        let event = eventTypeId.map { #""\#($0)""# } ?? "null"
        let json = """
        {"id":"\(id)","event_type_id":\(event),"day_of_week":\(day),\
        "start_time":"\(start)","end_time":"\(end)"}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(SchedulingAvailabilityRule.self, from: Data(json.utf8))
    }
}
