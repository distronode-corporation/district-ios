import DistrictData
import DistrictModel
import Foundation
import Observation

/// Asking for a booking's meeting notes to be written again.
///
/// ⛔ IT RETURNS AS SOON AS THE WORK IS QUEUED, AND THIS MODEL SAYS SO RATHER THAN
/// HANDING BACK THE BODY AS IF IT WERE THE NEW NOTES. `bookings.notes.regenerate`
/// ordinarily answers `status: "pending"` with `content` still holding the
/// PREVIOUS text, and it carries no `updated_at` at all — which is why its
/// response is a third shape rather than ``SchedulingBookingNotes``. The web
/// renders the body into the notes pane and never renders its `status`, so on a
/// slow job it shows the old notes as though they were fresh. This one reports
/// what actually happened and leaves the re-read to the screen.
///
/// ⛔ NO CONFIRMATION, MATCHING THE WEB. Nothing is destroyed: the far end can
/// write the summary again, so a dialog here would be ceremony in front of a safe
/// button. ⚠️ ``onQueued`` is where a screen should schedule its own re-read; this
/// model deliberately does not poll, because nothing in the response says when the
/// job finished.
@MainActor
@Observable
final class SchedulingBookingNotesModel {
    private(set) var state: SchedulingWritesBState = .idle

    private let admin: SchedulingAdminRepository
    private let workspaceId: String
    private let bookingId: String
    private let onQueued: (SchedulingBookingNotesRegenerated) -> Void

    init(
        admin: SchedulingAdminRepository,
        workspaceId: String,
        bookingId: String,
        onQueued: @escaping (SchedulingBookingNotesRegenerated) -> Void
    ) {
        self.admin = admin
        self.workspaceId = workspaceId
        self.bookingId = bookingId
        self.onQueued = onQueued
    }

    var busy: Bool {
        state.isWorking
    }

    func regenerate() async {
        guard !busy else { return }
        state = .working
        do {
            let answer = try await admin.regenerateBookingNotes(
                workspaceId: workspaceId,
                bookingId: bookingId
            )
            state = .done(SchedulingBookingWriteCopy.regenerateDone)
            onQueued(answer)
        } catch {
            state = .failed(SchedulingWritesBFailure.text(for: error))
        }
    }
}
