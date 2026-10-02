import DistrictData
import DistrictModel
import Foundation
import Observation

/// Which calendars inside one connected account are read for conflicts, and which
/// one new bookings are written to.
///
/// ⛔ THE PUT IS A REPLACE, NOT A PATCH, AND A CALENDAR LEFT OUT IS A CALENDAR
/// TURNED OFF. So this model loads the whole list, edits it in place and sends all
/// of it back — never an array built from the one row somebody touched. A holiday
/// calendar the GET reported with neither `writable` nor `primary` has to go back
/// the way it came.
///
/// ⛔ AND THE FOUR FLAGS ARE OPTIONAL FOR A REASON: absent and `false` are not the
/// same statement to the fork, and `JSONValue.object(_:)` drops a nil rather than
/// sending `false`. A row nobody touched therefore keeps its nils. ⚠️ Choosing a
/// destination is the one action that writes a flag onto EVERY row (`is_destination`
/// becomes true on one and false on the rest), which is what the browser's radio
/// group does and is the only way to say "this one, not those".
///
/// ⚠️ TWO WRITES ON SAVE, AND THE SECOND IS NOT REDUNDANT. The PUT stores which
/// calendars are checked and which is the destination; `calendar.connections.destination`
/// moves the ACCOUNT-level destination to this account. The fork's own
/// `SetAccountCalendars` does move it too, so the second call is belt and braces on
/// the one choice whose silent failure mode is "I chose it and bookings still go
/// somewhere else".
@MainActor
@Observable
final class SchedulingCalendarPickerModel {
    let connection: SchedulingCalendarConnection

    /// nil means "not read yet". ⚠️ An EMPTY array is a legitimate answer (an
    /// account with no calendars in it) and must not be rendered as a failure.
    private(set) var rows: [SchedulingCalendarSelection]?
    private(set) var failure: FailureText?
    private(set) var busy = false
    private(set) var saved = false

    private let repository: SchedulingAdminRepository
    private let workspaceId: String
    private let onChanged: () -> Void

    init(
        repository: SchedulingAdminRepository,
        workspaceId: String,
        connection: SchedulingCalendarConnection,
        onChanged: @escaping () -> Void
    ) {
        self.repository = repository
        self.workspaceId = workspaceId
        self.connection = connection
        self.onChanged = onChanged
    }

    /// ⛔ ONLY WRITABLE CALENDARS MAY RECEIVE BOOKINGS, and `writable == nil` counts
    /// as writable: the flag is absent on a row the fork did not describe, and
    /// treating absence as "read only" would hide the primary calendar of an account
    /// whose GET happened to omit it.
    var destinationChoices: [SchedulingCalendarSelection] {
        (rows ?? []).filter { $0.writable != false }
    }

    var destinationId: String? {
        rows?.first { $0.isDestination == true }?.id
    }

    var canSave: Bool {
        !busy && rows != nil
    }

    func load() async {
        guard !busy else { return }
        busy = true
        failure = nil
        do {
            rows = try await repository.connectionCalendars(
                workspaceId: workspaceId,
                connectionId: connection.id,
                provider: connection.provider,
                accountEmail: connection.accountEmail
            )
        } catch {
            rows = nil
            failure = SchedulingFailureCopy.text(forAny: error)
        }
        busy = false
    }

    /// ⚠️ WRITES AN EXPLICIT BOOLEAN ONTO THE ONE ROW AND LEAVES THE OTHERS ALONE.
    /// Conflict checking is a per-calendar question and any number may be on, so
    /// there is nothing here that has to touch a row the user did not.
    func setCheckConflicts(_ id: String, on: Bool) {
        rows = rows?.map { row in
            guard row.id == id else { return row }
            return SchedulingCalendarSelection(
                id: row.id,
                name: row.name,
                primary: row.primary,
                writable: row.writable,
                checkConflicts: on,
                isDestination: row.isDestination
            )
        }
    }

    /// ⛔ EXACTLY ONE CONNECTION HOLDS THE DESTINATION, so this is a move rather
    /// than a toggle: every other row is set explicitly false. There is no call
    /// that CLEARS a destination, which is why nothing here offers to deselect.
    func chooseDestination(_ id: String) {
        rows = rows?.map { row in
            SchedulingCalendarSelection(
                id: row.id,
                name: row.name,
                primary: row.primary,
                writable: row.writable,
                checkConflicts: row.checkConflicts,
                isDestination: row.id == id
            )
        }
    }

    func save() async {
        guard !busy, let rows else { return }
        busy = true
        failure = nil
        saved = false
        do {
            _ = try await repository.setConnectionCalendars(
                workspaceId: workspaceId,
                connectionId: connection.id,
                provider: connection.provider,
                calendars: rows,
                accountEmail: connection.accountEmail
            )
            if rows.contains(where: { $0.isDestination == true }) {
                _ = try await repository.setDestinationConnection(
                    workspaceId: workspaceId,
                    connectionId: connection.id,
                    provider: connection.provider,
                    accountEmail: connection.accountEmail
                )
            }
            busy = false
            saved = true
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
