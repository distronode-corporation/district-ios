import DistrictData
import DistrictModel
import Foundation
import Observation

/// The candidate hosts a booking can be handed to.
enum SchedulingReassignHostsState {
    case loading
    case ready([SchedulingUser])
    case failed(FailureText)
}

/// Handing one booking to a different host.
///
/// ⛔ THE CANDIDATE LIST IS `users.list` MINUS THE ARCHIVED AND MINUS THE CURRENT
/// HOST, which is the web bookings table's filter exactly. An archived user is
/// skipped in routing and cannot sign in, so offering one is offering a booking
/// nobody will take; the current host is not a change.
///
/// ⛔ `hostId` IS A SCHEDULER USER'S ID, NOT A DISTRONODE MEMBER ID. The two
/// populations are different and the join lives inside the fork — a member id sent
/// here is a refusal, not a mis-assignment.
///
/// ⚠️ THE OP IS ADMIN-ONLY AT THE FAR END AND THE ROLE THAT DECIDES IT IS THE
/// SCHEDULER'S, NOT DISTRONODE'S. The web gates this control on the signed-in
/// scheduler profile's `is_admin` rather than on District's own `canManage`,
/// because the fork's handler answers 403 "admin access required". The caller owns
/// that gate; this model does not re-derive it, and a refusal still arrives as
/// ``SchedulingAdminError/forbidden`` with an honest sentence.
@MainActor
@Observable
final class SchedulingBookingReassignModel {
    private(set) var state: SchedulingWritesBState = .idle
    private(set) var hosts: SchedulingReassignHostsState = .loading
    private(set) var selectedHostId: String?

    private let admin: SchedulingAdminRepository
    private let workspaceId: String
    private let bookingId: String
    private let currentHostId: String?
    private let onSaved: (SchedulingBooking) -> Void

    init(
        admin: SchedulingAdminRepository,
        workspaceId: String,
        bookingId: String,
        currentHostId: String?,
        onSaved: @escaping (SchedulingBooking) -> Void
    ) {
        self.admin = admin
        self.workspaceId = workspaceId
        self.bookingId = bookingId
        self.currentHostId = currentHostId
        self.onSaved = onSaved
    }

    var busy: Bool {
        state.isWorking
    }

    var candidates: [SchedulingUser] {
        guard case let .ready(rows) = hosts else { return [] }
        return rows
    }

    var canSubmit: Bool {
        selectedHostId != nil && !busy
    }

    func select(_ userId: String) {
        selectedHostId = userId
        if case .failed = state {
            state = .idle
        }
    }

    /// ⚠️ `users.list` ANSWERS A BARE ARRAY, not `{items}`. The repository absorbs
    /// that; this is only a note against anyone tempted to reach past it.
    func loadHosts() async {
        hosts = .loading
        do {
            let rows = try await admin.schedulerUsers(workspaceId: workspaceId)
            hosts = .ready(rows.filter { !$0.archived && $0.id != currentHostId })
        } catch {
            hosts = .failed(SchedulingWritesBFailure.text(for: error))
        }
    }

    func submit() async {
        guard !busy, let hostId = selectedHostId else { return }
        state = .working
        do {
            let booking = try await admin.reassignBooking(
                workspaceId: workspaceId,
                bookingId: bookingId,
                hostId: hostId
            )
            state = .done(SchedulingBookingWriteCopy.reassignDone)
            onSaved(booking)
        } catch {
            state = .failed(SchedulingWritesBFailure.text(for: error))
        }
    }

    /// ⚠️ NAME, FALLING BACK TO EMAIL. A scheduler user always has both columns and
    /// a blank name is reachable through SSO; an empty row is unpickable.
    static func label(for user: SchedulingUser) -> String {
        user.name.isEmpty ? user.email : user.name
    }
}
