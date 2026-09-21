import DistrictData
import DistrictModel
import Foundation
import Observation

/// Cancelling one booking, with the optional reason that travels in the
/// attendee's email.
///
/// ⛔ THE ANSWER IS THE CANCELLED BOOKING, NOT AN ACKNOWLEDGEMENT, AND ``onSaved``
/// HANDS IT BACK WHOLE. `updated_at` and `cancellation_reason` both move, and the
/// far end may normalise the reason it was sent — so a list that flipped its own
/// row's status would be showing a row the server does not have.
///
/// ⚠️ THE REASON IS OMITTED WHEN BLANK RATHER THAN SENT AS `""`. The catalog marks
/// it `.optional()` and `JSONValue.object(_:)` drops a nil pair, which is what
/// makes "no reason" an absent key instead of an empty one the fork would put in
/// the email.
@MainActor
@Observable
final class SchedulingBookingCancelModel {
    private(set) var state: SchedulingWritesBState = .idle
    private(set) var reason = ""
    /// ⚠️ Set only by ``submit()``'s own validation, cleared on the next edit, and
    /// deliberately NOT a ``SchedulingWritesBState/failed(_:)``: no request was
    /// spent, so offering a retry would be describing a failure that never
    /// happened.
    private(set) var reasonRejected: String?

    private let admin: SchedulingAdminRepository
    private let workspaceId: String
    private let bookingId: String
    private let onSaved: (SchedulingBooking) -> Void

    init(
        admin: SchedulingAdminRepository,
        workspaceId: String,
        bookingId: String,
        onSaved: @escaping (SchedulingBooking) -> Void
    ) {
        self.admin = admin
        self.workspaceId = workspaceId
        self.bookingId = bookingId
        self.onSaved = onSaved
    }

    var busy: Bool {
        state.isWorking
    }

    func editReason(_ value: String) {
        reason = value
        reasonRejected = nil
        if case .failed = state {
            state = .idle
        }
    }

    /// ⛔ THE CEILING IS ENFORCED HERE THOUGH THE WEB LEAVES IT TO ZOD. The catalog
    /// caps the reason at 1000 characters and a longer one comes back as
    /// ``SchedulingAdminError/invalidParams`` carrying the FIELD NAME and no
    /// message — which on a phone is a refusal with nothing an operator can act on.
    /// Checking first costs one comparison and turns it into a sentence.
    func submit() async {
        guard !busy else { return }
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= Self.reasonLimit else {
            reasonRejected = SchedulingBookingWriteCopy.cancelReasonTooLong
            return
        }
        state = .working
        do {
            let booking = try await admin.cancelBooking(
                workspaceId: workspaceId,
                bookingId: bookingId,
                reason: trimmed.isEmpty ? nil : trimmed
            )
            state = .done(SchedulingBookingWriteCopy.cancelDone)
            onSaved(booking)
        } catch {
            state = .failed(SchedulingWritesBFailure.text(for: error))
        }
    }

    static let reasonLimit = 1000
}
