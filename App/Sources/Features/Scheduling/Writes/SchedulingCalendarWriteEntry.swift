import DistrictData
import DistrictModel
import SwiftUI

/// The controls that open the calendar screen's writes.
///
/// ⛔ NONE OF THESE IS GATED ON ``WorkspaceRole/allowsMutation(_:)``, AND THAT IS
/// THE SERVER'S RULE RATHER THAN A RELAXATION. `calendar.caldav.connect`,
/// `calendar.connections.calendars.put`, `calendar.connections.destination` and
/// `calendar.connections.delete` are all `viewer`-level in the op catalog, because
/// they touch only the CALLER's own calendars — somebody who cannot connect their
/// own calendar cannot be booked at all. Gating them would break the product for
/// exactly the role the narrow rule exists to protect.
extension SchedulingWriteCopyC {
    static let calendarsOpen = "Choose calendars"
}

/// "Connect a CalDAV calendar".
///
/// ⚠️ A FRESH MODEL PER PRESS, so the app password box opens empty. The sheet's own
/// header records why nothing reads that value back.
struct SchedulingCaldavConnectButton: View {
    let admin: SchedulingAdminRepository
    let workspaceId: String
    let onChanged: () -> Void

    @State private var connecting: SchedulingWritePresentation<SchedulingCaldavConnectModel>?

    var body: some View {
        Button(SchedulingWriteCopyC.caldavTitle) {
            connecting = SchedulingWritePresentation(model: makeModel())
        }
        .buttonStyle(.districtSecondary)
        .accessibilityIdentifier(A11yID.SchedulingWriteEntry.caldavConnect)
        .sheet(item: $connecting) { entry in
            SchedulingCaldavConnectSheet(model: entry.model)
        }
    }

    private func makeModel() -> SchedulingCaldavConnectModel {
        SchedulingCaldavConnectModel(
            repository: admin,
            workspaceId: workspaceId,
            onChanged: onChanged
        )
    }
}

/// "Choose calendars" and "Disconnect", on one connection.
///
/// ⛔ THE PICKER TAKES THE CONNECTION RATHER THAN ITS ID. `calendar.connections.*`
/// is addressed by provider AND account as well — the fork recreates a connection
/// id on every token refresh — so a sheet built from an id alone would address a
/// connection that no longer answers to it.
///
/// ⚠️ THE DISCONNECT MODEL IS THE SCREEN'S AND THE PROMPT IS THIS ROW'S: one model
/// holding the pending row, and a dialog here that presents only while it is this
/// one, for the reason ``SchedulingWriteConfirmationsC`` records.
struct SchedulingCalendarRowActions: View {
    let admin: SchedulingAdminRepository
    let workspaceId: String
    let connection: SchedulingCalendarConnection
    let disconnectModel: SchedulingCalendarDisconnectModel
    let onChanged: () -> Void

    @State private var choosing: SchedulingWritePresentation<SchedulingCalendarPickerModel>?

    var body: some View {
        HStack(spacing: DistrictSpacing.tight) {
            Button(SchedulingWriteCopyC.calendarsOpen) {
                choosing = SchedulingWritePresentation(model: makeModel())
            }
            .buttonStyle(.districtSecondary)
            .accessibilityIdentifier(
                A11yID.row(A11yID.SchedulingWriteEntry.calendarSelect, connection.id)
            )
            Button(SchedulingWriteCopyC.disconnectAction) { disconnectModel.ask(connection) }
                .buttonStyle(.districtGhost)
                .disabled(disconnectModel.busy)
                .accessibilityIdentifier(
                    A11yID.row(A11yID.SchedulingCalendarWrites.disconnect, connection.id)
                )
                .schedulingDisconnectCalendarDialogC(disconnectModel, for: connection)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $choosing) { entry in
            SchedulingCalendarPickerSheet(model: entry.model)
        }
    }

    private func makeModel() -> SchedulingCalendarPickerModel {
        SchedulingCalendarPickerModel(
            repository: admin,
            workspaceId: workspaceId,
            connection: connection,
            onChanged: onChanged
        )
    }
}
