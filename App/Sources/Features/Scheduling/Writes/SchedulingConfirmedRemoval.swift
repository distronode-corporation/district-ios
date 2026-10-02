import DistrictData
import DistrictModel
import Foundation
import Observation

/// Remove one row, behind a confirmation.
///
/// ⛔ ONE STATE MACHINE FOR EVERY CONFIRM-THEN-DELETE ON THE SURFACE, AND THE OP IS
/// BOUND AT INIT. Revoking a key, signing an app out, deleting a webhook and unlinking
/// a calendar differ only in the repository call; four copies of the same `confirm()`
/// meant every single-flight or failure change was made four times. Each binding below
/// is a separate `Row` type with its own initialiser, so the wrong delete is a type
/// error rather than one wrong argument away.
///
/// ⛔ DESTRUCTIVE AND IMMEDIATE: every bound op answers nothing and has no undo, so the
/// prompt names the row and says what stops working. ⚠️ The pending ROW is held rather
/// than an id, because the prompt has to name it and reading a name back out of a list
/// that has already been re-read would be a race.
@MainActor
@Observable
final class SchedulingConfirmedRemoval<Row: Sendable> {
    private(set) var pending: Row?
    private(set) var busy = false
    private(set) var failure: FailureText?
    /// ⚠️ THE ROW THE LAST CONFIRMED REMOVAL TOOK, kept until the next prompt opens.
    /// Recorded before the re-read, because after it there is nothing left to ask
    /// about what was deleted (see ``removedDestination``).
    private(set) var removed: Row?

    private let remove: @Sendable (Row) async throws -> Void
    private let onChanged: () -> Void

    init(onChanged: @escaping () -> Void, remove: @escaping @Sendable (Row) async throws -> Void) {
        self.onChanged = onChanged
        self.remove = remove
    }

    var isAsking: Bool {
        pending != nil
    }

    func ask(_ row: Row) {
        guard !busy else { return }
        failure = nil
        removed = nil
        pending = row
    }

    func cancel() {
        pending = nil
    }

    /// ⚠️ THE PROMPT IS DISMISSED BEFORE THE ANSWER LANDS, matching the browser: a
    /// confirmation that stays up under a spinner invites a second press on a request
    /// already in flight. The failure, if there is one, is reported on the screen
    /// behind it.
    func confirm() async {
        guard !busy, let row = pending else { return }
        busy = true
        pending = nil
        failure = nil
        do {
            try await remove(row)
            busy = false
            removed = row
            onChanged()
        } catch {
            busy = false
            failure = SchedulingFailureCopy.text(forAny: error)
        }
    }

    func dismissFailure() {
        failure = nil
    }
}

// MARK: - The four bindings

/// Revoke one API key.
typealias SchedulingAPIKeyRevokeModel = SchedulingConfirmedRemoval<SchedulingAPIKey>

extension SchedulingConfirmedRemoval where Row == SchedulingAPIKey {
    convenience init(
        repository: SchedulingAdminRepository,
        workspaceId: String,
        onChanged: @escaping () -> Void
    ) {
        self.init(onChanged: onChanged) { key in
            _ = try await repository.deleteAPIKey(workspaceId: workspaceId, keyId: key.id)
        }
    }
}

/// Sign one third-party app out of this workspace's booking data.
///
/// ⚠️ NOT AN API KEY, THOUGH THE TWO LISTS LOOK ALIKE. A key is minted BY the customer
/// and revoked by deleting it; a connection is granted TO an app by a person consenting,
/// and deleting it signs that app out. They are separate ops on separate row types.
///
/// ⛔ `clientName` IS UNTRUSTED TEXT (whatever the app registered), so it is a label in
/// a prompt and never an identity anything authorises against. The op takes the row's
/// `id`.
typealias SchedulingOAuthConnectionRevokeModel = SchedulingConfirmedRemoval<SchedulingOAuthConnection>

extension SchedulingConfirmedRemoval where Row == SchedulingOAuthConnection {
    convenience init(
        repository: SchedulingAdminRepository,
        workspaceId: String,
        onChanged: @escaping () -> Void
    ) {
        self.init(onChanged: onChanged) { connection in
            _ = try await repository.deleteOAuthConnection(
                workspaceId: workspaceId,
                connectionId: connection.id
            )
        }
    }
}

/// Delete one webhook.
typealias SchedulingWebhookDeleteModel = SchedulingConfirmedRemoval<SchedulingWebhook>

extension SchedulingConfirmedRemoval where Row == SchedulingWebhook {
    convenience init(
        repository: SchedulingAdminRepository,
        workspaceId: String,
        onChanged: @escaping () -> Void
    ) {
        self.init(onChanged: onChanged) { webhook in
            _ = try await repository.deleteWebhook(workspaceId: workspaceId, webhookId: webhook.id)
        }
    }
}

/// Unlink one calendar account.
///
/// ⚠️ `provider` IS REQUIRED AND THE `{id}` IS DECORATIVE. The fork recreates a
/// connection id on every token refresh, so identity is `provider` + `account`; a
/// client that sent only the id would address a connection that no longer answers
/// to it.
typealias SchedulingCalendarDisconnectModel = SchedulingConfirmedRemoval<SchedulingCalendarConnection>

extension SchedulingConfirmedRemoval where Row == SchedulingCalendarConnection {
    convenience init(
        repository: SchedulingAdminRepository,
        workspaceId: String,
        onChanged: @escaping () -> Void
    ) {
        self.init(onChanged: onChanged) { connection in
            _ = try await repository.deleteCalendarConnection(
                workspaceId: workspaceId,
                connectionId: connection.id,
                provider: connection.provider,
                accountEmail: connection.accountEmail
            )
        }
    }

    /// ⛔ TRUE WHEN THE ACCOUNT JUST UNLINKED WAS THE ONE RECEIVING BOOKINGS. The
    /// catalog does not refuse removing the destination connection, and a tenancy left
    /// with none writes new bookings nowhere, so the screen has to SAY so afterwards
    /// rather than leaving the customer to discover it at the next booking.
    var removedDestination: Bool {
        removed?.isDestination == true
    }
}
