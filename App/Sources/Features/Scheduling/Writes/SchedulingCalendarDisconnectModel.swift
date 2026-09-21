import DistrictData
import DistrictModel
import Foundation
import Observation

/// Unlink one calendar account, behind a confirmation.
///
/// ⛔ THIS CAN REMOVE THE DESTINATION CONNECTION AND THE CATALOG DOES NOT REFUSE
/// IT. A tenancy left with no destination writes new bookings nowhere, so the
/// screen has to SAY so afterwards rather than leaving the customer to discover it
/// at the next booking. ``removedDestination`` is set from the row that was
/// deleted, before the re-read, because after it there is nothing left to ask.
///
/// ⚠️ `provider` IS REQUIRED AND THE `{id}` IS DECORATIVE. The fork recreates a
/// connection id on every token refresh, so identity is `provider` + `account`; a
/// client that sent only the id would address a connection that no longer answers
/// to it.
@MainActor
@Observable
final class SchedulingCalendarDisconnectModel {
    private(set) var pending: SchedulingCalendarConnection?
    private(set) var busy = false
    private(set) var failure: FailureText?
    /// ⛔ TRUE WHEN THE ACCOUNT JUST UNLINKED WAS THE ONE RECEIVING BOOKINGS.
    private(set) var removedDestination = false

    private let repository: SchedulingAdminRepository
    private let workspaceId: String
    private let onChanged: () -> Void

    init(
        repository: SchedulingAdminRepository,
        workspaceId: String,
        onChanged: @escaping () -> Void
    ) {
        self.repository = repository
        self.workspaceId = workspaceId
        self.onChanged = onChanged
    }

    var isAsking: Bool {
        pending != nil
    }

    func ask(_ connection: SchedulingCalendarConnection) {
        guard !busy else { return }
        failure = nil
        removedDestination = false
        pending = connection
    }

    func cancel() {
        pending = nil
    }

    func confirm() async {
        guard !busy, let connection = pending else { return }
        busy = true
        pending = nil
        failure = nil
        do {
            _ = try await repository.deleteCalendarConnection(
                workspaceId: workspaceId,
                connectionId: connection.id,
                provider: connection.provider,
                accountEmail: connection.accountEmail
            )
            busy = false
            removedDestination = connection.isDestination
            onChanged()
        } catch {
            busy = false
            failure = FailureText.schedulingWriteC(thrown: error)
        }
    }

    func dismissFailure() {
        failure = nil
    }

    func dismissDestinationWarning() {
        removedDestination = false
    }
}
