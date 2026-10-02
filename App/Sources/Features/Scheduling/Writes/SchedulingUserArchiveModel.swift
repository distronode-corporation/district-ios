import DistrictData
import DistrictModel
import Foundation
import Observation

/// What is standing between a scheduler user and an archive.
enum SchedulingUpcomingBookingsState {
    case loading
    case ready([SchedulingUpcomingBooking])
    case failed(FailureText)
}

/// Offboarding one scheduler user.
///
/// ⛔ THE ARCHIVE IS BLOCKED UNTIL THE UPCOMING-BOOKING COUNT HAS BEEN READ AND IS
/// ZERO, AND THAT IS THE FORK'S DESIGN RATHER THAN A RACE WE ARE AVOIDING.
/// `users.archive` refuses with a 409 while the user still hosts anything:
/// reassign or cancel, then archive. `users.upcomingBookings` is the read that
/// makes the first step possible, which is why it belongs beside the archive and
/// not with the bookings namespace. ``canArchive`` is false while the read is in
/// flight for the same reason the web's is — offering the button before the answer
/// is offering a refusal.
///
/// ⛔ AND A REFUSAL CANNOT BE EXPLAINED SPECIFICALLY FROM THIS SIDE. The fork's
/// four 4xx answers (409 still hosting, 403 not the owner, 400 owner or already
/// archived, 404 gone) are all collapsed to ``SchedulingAdminError/unknown`` by
/// `error(forStatus:code:)` before a screen sees them, so
/// ``SchedulingTeamWriteCopy/archiveRefused`` enumerates instead of asserting.
///
/// ⚠️ SOFT, AND THAT IS WHAT MAKES IT SAFE TO OFFER AT ALL. The row and its links
/// survive; the member cannot sign in, is skipped in routing and their event types
/// are deactivated. The copy says so rather than saying "delete".
@MainActor
@Observable
final class SchedulingUserArchiveModel {
    private(set) var state: SchedulingWriteState = .idle
    private(set) var upcoming: SchedulingUpcomingBookingsState = .loading

    private let admin: SchedulingAdminRepository
    private let workspaceId: String
    private let userId: String
    private let userName: String
    private let onArchived: (String) -> Void

    init(
        admin: SchedulingAdminRepository,
        workspaceId: String,
        userId: String,
        userName: String,
        onArchived: @escaping (String) -> Void
    ) {
        self.admin = admin
        self.workspaceId = workspaceId
        self.userId = userId
        self.userName = userName
        self.onArchived = onArchived
    }

    var busy: Bool {
        state.isWorking
    }

    var bookings: [SchedulingUpcomingBooking] {
        guard case let .ready(rows) = upcoming else { return [] }
        return rows
    }

    /// ⛔ REQUIRES A SUCCESSFUL READ, NOT MERELY AN EMPTY LIST. A failed read
    /// answers `[]` through ``bookings`` and must not unlock the button — "we could
    /// not look" and "there is nothing" are different answers, which is the rule
    /// ``FailureText`` exists to enforce.
    var canArchive: Bool {
        guard case let .ready(rows) = upcoming else { return false }
        return rows.isEmpty && !busy
    }

    /// The sentence under a blocked button. ⚠️ Says WHY rather than leaving a
    /// disabled control unexplained.
    var blockedReason: String? {
        switch upcoming {
        case .loading:
            SchedulingTeamWriteCopy.archiveCounting
        case let .ready(rows):
            rows.isEmpty ? nil : SchedulingTeamWriteCopy.archiveBlocked
        case .failed:
            SchedulingTeamWriteCopy.archiveCounting
        }
    }

    func loadUpcoming() async {
        upcoming = .loading
        do {
            upcoming = try await .ready(admin.upcomingBookings(workspaceId: workspaceId, userId: userId))
        } catch {
            upcoming = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    /// ⚠️ RE-CHECKS ``canArchive`` RATHER THAN TRUSTING A DISABLED BUTTON. A
    /// view-only guard is not something anything else can make a claim about, and
    /// this one is the difference between a refusal and a request nobody meant to
    /// send.
    func archive() async {
        guard canArchive else { return }
        state = .working
        do {
            _ = try await admin.archiveSchedulerUser(workspaceId: workspaceId, userId: userId)
            state = .done(SchedulingTeamWriteCopy.archiveDone(userName))
            onArchived(userId)
        } catch {
            state = .failed(Self.refusal(error))
        }
    }

    /// ⛔ THE ONE PLACE THE ENUMERATED SENTENCE IS PREFERRED TO THE SHARED GENERIC.
    /// Every other write's ``SchedulingAdminError/unknown`` really is unknown; on
    /// this op the set of 4xx answers is documented and small, so naming all of
    /// them is more useful than "That did not save." and is still true. ⚠️ Every
    /// other arm keeps the shared mapping, so a 5xx still reads as a 5xx.
    ///
    /// ⛔ IT MATCHES THE `unknown` **CASE**, NOT `uiCode == .unknown`, AND THE
    /// DIFFERENCE IS TWO REAL ERRORS. `invalidParams` and `decoding` both collapse
    /// to that same ui code, and neither is an archive refusal — telling somebody
    /// their account "may be the workspace owner" when the app failed to parse a
    /// response would be this client inventing a cause for its own bug.
    static func refusal(_ error: Error) -> FailureText {
        guard let admin = error as? SchedulingAdminError, case .unknown = admin else {
            return SchedulingFailureCopy.text(forAny: error)
        }
        return FailureText(message: SchedulingTeamWriteCopy.archiveRefused, action: .none)
    }
}
