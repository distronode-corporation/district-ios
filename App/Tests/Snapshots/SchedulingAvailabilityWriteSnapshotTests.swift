@testable import DistrictAI
import DistrictData
import SwiftUI
import XCTest

/// Working hours and the days off, each read by its sheet from the recorded answers.
///
/// ⚠️ "TODAY" IS FIXED to the day before the recorded overrides, so the rows the sheet
/// hides once they are past stay on screen whenever this runs.
final class SchedulingAvailabilityWriteSnapshotTests: SchedulingWriteSnapshotCase {
    private static let today = "2026-09-01"

    // MARK: - Working hours

    func testRulesRecorded() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingAvailabilityRulesSheet(model: self.rules(container))
        }
    }

    /// No hours at all: every day reads as unavailable.
    func testRulesEmpty() async throws {
        try await assertScreen(["op:availability.rules.list": .noItems], devices: [.iPhone]) { container in
            SchedulingAvailabilityRulesSheet(model: self.rules(container))
        }
    }

    func testRulesReadRefused() async throws {
        try await assertScreen(["op:availability.rules.list": .notReady], devices: [.iPhone]) { container in
            SchedulingAvailabilityRulesSheet(model: self.rules(container))
        }
    }

    /// A window that ends before it starts: the row's own sentence, and Save switched off.
    func testRulesRangeOutOfOrder() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            let model = self.rules(container)
            return SnapshotPrepared(SchedulingAvailabilityRulesSheet(model: model)) {
                await firstReadLanded { model.week.contains { !$0.isEmpty } }
                guard let row = model.week.firstIndex(where: { !$0.isEmpty }),
                      let range = model.week[row].first
                else {
                    XCTFail("the recorded hours did not load")
                    return
                }
                model.setEnd("08:00", for: range.id, inRow: row)
            }
        }
    }

    /// Save pressed on hours nobody changed: a sentence, and no write.
    func testRulesNothingToSave() async throws {
        try await assertScreen(devices: [.iPhone], locales: [.en]) { container in
            let model = self.rules(container)
            return SnapshotPrepared(SchedulingAvailabilityRulesSheet(model: model)) {
                await firstReadLanded { model.week.contains { !$0.isEmpty } }
                await model.save()
            }
        }
    }

    /// A second window added to a day and the first day's hours copied across the week.
    func testRulesEditedWeek() async throws {
        try await assertScreen(devices: [.iPhone], locales: [.en]) { container in
            let model = self.rules(container)
            return SnapshotPrepared(SchedulingAvailabilityRulesSheet(model: model)) {
                await firstReadLanded { model.week.contains { !$0.isEmpty } }
                guard let row = model.week.firstIndex(where: { !$0.isEmpty }) else {
                    XCTFail("the recorded hours did not load")
                    return
                }
                model.copyToWeekdays(from: row)
                model.addRange(toRow: row)
            }
        }
    }

    // MARK: - Days off

    func testOverridesRecorded() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingAvailabilityOverridesSheet(model: self.overrides(container))
        }
    }

    func testOverridesEmpty() async throws {
        try await assertScreen(["op:availability.overrides.list": .noItems], devices: [.iPhone]) { container in
            SchedulingAvailabilityOverridesSheet(model: self.overrides(container))
        }
    }

    func testOverridesReadRefused() async throws {
        try await assertScreen(["op:availability.overrides.list": .refused], devices: [.iPhone]) { container in
            SchedulingAvailabilityOverridesSheet(model: self.overrides(container))
        }
    }

    /// A refused delete leaves the row, with the scheduler's sentence under the list.
    func testOverridesDeleteRefused() async throws {
        try await assertScreen(
            ["op:availability.overrides.delete": .refused, "op:availability.overrides.deleteGroup": .refused],
            devices: [.iPhone],
            locales: [.en]
        ) { container in
            let model = self.overrides(container)
            return SnapshotPrepared(SchedulingAvailabilityOverridesSheet(model: model)) {
                await firstReadLanded { !model.rows.isEmpty }
                guard let row = model.rows.first else {
                    XCTFail("the recorded overrides did not load")
                    return
                }
                model.beginDelete(row)
                await model.delete()
            }
        }
    }

    // MARK: - Adding one

    /// The form as "Add" opens it: a day off, first and last day.
    func testOverrideAddDayOff() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            let model = self.overrides(container)
            model.beginAdd()
            return SchedulingAvailabilityOverridesSheet(model: model, addFormOnly: true)
        }
    }

    /// Custom hours: one date and a window, and no last-day field.
    func testOverrideAddCustomHours() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            let model = self.overrides(container)
            model.beginAdd()
            model.updateAdding { form in
                form.reason = "custom_hours"
                form.date = "2026-09-30"
            }
            return SchedulingAvailabilityOverridesSheet(model: model, addFormOnly: true)
        }
    }

    private func rules(_ container: AppContainer) -> SchedulingAvailabilityRulesModel {
        SchedulingAvailabilityRulesModel(
            admin: container.schedulingAdmin,
            workspaceId: Self.workspace,
            onSaved: { _ in }
        )
    }

    private func overrides(_ container: AppContainer) -> SchedulingAvailabilityOverridesModel {
        SchedulingAvailabilityOverridesModel(
            admin: container.schedulingAdmin,
            workspaceId: Self.workspace,
            today: Self.today,
            onSaved: { _ in }
        )
    }
}
