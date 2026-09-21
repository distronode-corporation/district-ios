import DistrictData
import SwiftUI

/// The two editors behind the working-hours screen.
///
/// ⛔ THE WEEK EDITOR AND THE OVERRIDE EDITOR ARE SEPARATE SHEETS BECAUSE THEY ARE
/// SEPARATE WRITES. The week is a DIFF — `SchedulingWorkingHours` compares the
/// edited grid against the rules it loaded and emits creates, patches and deletes —
/// while an override is one row created or removed. Putting them in one form would
/// make an override's mistake capable of deleting a rule.
///
/// ⚠️ BOTH SHEETS LOAD THEIR OWN COPY of the rules and overrides rather than taking
/// the read screen's. The diff must be taken against what the server held when the
/// form opened, not against whatever the screen behind it read minutes ago.
///
/// ⚠️ `today` IS THE OPERATOR'S DAY, NOT THE DEVICE'S. The override list is filtered
/// from it, and a phone in another country would otherwise drop a day off that has
/// not started yet where the bookings are taken.
struct SchedulingHoursWriteBar: View {
    let admin: SchedulingAdminRepository
    let workspaceId: String
    let today: String
    let onChanged: () -> Void

    @State private var rules: SchedulingWritePresentation<SchedulingAvailabilityRulesModel>?
    @State private var overrides: SchedulingWritePresentation<SchedulingAvailabilityOverridesModel>?

    var body: some View {
        HStack(spacing: DistrictSpacing.tight) {
            Button(SchedulingWriteCopy.hoursTitle) {
                rules = SchedulingWritePresentation(model: rulesModel())
            }
            .buttonStyle(.districtPrimary)
            .accessibilityIdentifier(A11yID.SchedulingWriteEntry.hoursEdit)
            Button(SchedulingWriteCopy.overridesTitle) {
                overrides = SchedulingWritePresentation(model: overridesModel())
            }
            .buttonStyle(.districtSecondary)
            .accessibilityIdentifier(A11yID.SchedulingWriteEntry.overridesEdit)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $rules) { entry in
            SchedulingAvailabilityRulesSheet(model: entry.model)
        }
        .sheet(item: $overrides) { entry in
            SchedulingAvailabilityOverridesSheet(model: entry.model)
        }
    }

    private func rulesModel() -> SchedulingAvailabilityRulesModel {
        SchedulingAvailabilityRulesModel(
            admin: admin,
            workspaceId: workspaceId,
            onSaved: { _ in onChanged() }
        )
    }

    private func overridesModel() -> SchedulingAvailabilityOverridesModel {
        SchedulingAvailabilityOverridesModel(
            admin: admin,
            workspaceId: workspaceId,
            today: today,
            onSaved: { _ in onChanged() }
        )
    }
}
