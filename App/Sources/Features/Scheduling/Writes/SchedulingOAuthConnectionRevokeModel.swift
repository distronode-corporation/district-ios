import DistrictData
import DistrictModel
import Foundation
import Observation

/// Sign one third-party app out of this workspace's booking data.
///
/// ⚠️ NOT AN API KEY, THOUGH THE TWO LISTS LOOK ALIKE AND THIS MODEL READS LIKE
/// `SchedulingAPIKeyRevokeModel`. A key is minted BY the customer and revoked by
/// deleting it; a connection is granted TO an app by a person consenting, and
/// deleting it signs that app out. They are separate ops on separate rows, and a
/// single model parameterised by "which list" would make the wrong delete one
/// wrong argument away.
///
/// ⛔ `clientName` IS UNTRUSTED TEXT — whatever the app registered — so it is a
/// label in a prompt and never an identity anything authorises against. The op
/// takes the row's `id`.
@MainActor
@Observable
final class SchedulingOAuthConnectionRevokeModel {
    private(set) var pending: SchedulingOAuthConnection?
    private(set) var busy = false
    private(set) var failure: FailureText?

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

    func ask(_ connection: SchedulingOAuthConnection) {
        guard !busy else { return }
        failure = nil
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
            _ = try await repository.deleteOAuthConnection(
                workspaceId: workspaceId,
                connectionId: connection.id
            )
            busy = false
            onChanged()
        } catch {
            busy = false
            failure = FailureText.schedulingWriteC(thrown: error)
        }
    }

    func dismissFailure() {
        failure = nil
    }
}
