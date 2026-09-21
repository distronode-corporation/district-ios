import DistrictData
import SwiftUI

/// The two recording deletions: one row, or everything the tenancy holds.
///
/// ⛔ ONE MODEL PER ROW RATHER THAN ONE PER SCREEN, AND THAT IS A CORRECTNESS
/// DECISION RATHER THAN A TIDINESS ONE. ``SchedulingRecordingDeleteModel`` carries
/// the busy flag and the sentence the button reports underneath itself, so a single
/// shared instance would put one row's "Recording deleted" — or one row's failure —
/// under every other row on the screen.
struct SchedulingRecordingDeleteEntry: View {
    let admin: SchedulingAdminRepository
    let workspaceId: String
    let recordingId: String
    let onDeleted: () -> Void

    /// ⚠️ BUILT ONCE PER APPEARANCE, NOT PER REDRAW. The model holds the sentence
    /// left behind by the delete it just ran; rebuilding it in `body` would drop
    /// that the first time anything else on the screen changed.
    @State private var model: SchedulingRecordingDeleteModel?

    var body: some View {
        Group {
            if let model {
                SchedulingRecordingDeleteButton(
                    model: model,
                    recordingId: recordingId,
                    label: SchedulingWriteCopy.delete
                )
            }
        }
        .onAppear {
            guard model == nil else { return }
            model = SchedulingRecordingDeleteModel(
                admin: admin,
                workspaceId: workspaceId,
                onDeleted: onDeleted
            )
        }
    }
}

/// "Delete all recordings", behind the typed confirmation.
///
/// ⛔ A FRESH MODEL PER PRESS, WHICH IS WHAT CLEARS THE TYPED WORD. The gate is
/// satisfied by the exact lower-case `delete`; carrying a satisfied field from one
/// presentation into the next would leave the most destructive control on the
/// surface already armed when the sheet opened.
struct SchedulingRecordingDeleteAllButton: View {
    let admin: SchedulingAdminRepository
    let workspaceId: String
    let onDeleted: () -> Void

    @State private var deleting: SchedulingWritePresentation<SchedulingRecordingDeleteModel>?

    var body: some View {
        Button(SchedulingRecordingWriteCopy.deleteAll) {
            deleting = SchedulingWritePresentation(model: makeModel())
        }
        .buttonStyle(.districtDestructive)
        .accessibilityIdentifier(A11yID.SchedulingWriteEntry.recordingDeleteAll)
        .sheet(item: $deleting) { entry in
            SchedulingRecordingDeleteAllSheet(model: entry.model) { deleting = nil }
        }
    }

    private func makeModel() -> SchedulingRecordingDeleteModel {
        SchedulingRecordingDeleteModel(
            admin: admin,
            workspaceId: workspaceId,
            onDeleted: onDeleted
        )
    }
}
