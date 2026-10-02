import DistrictData
import DistrictModel
import Foundation
import Observation

/// The four things that can be done TO an event type rather than IN it: turn it
/// on or off, archive or restore it, send yourself one of its emails, delete it.
///
/// ⛔ SEPARATE FROM ``SchedulingEventTypeEditorModel`` BECAUSE NONE OF THEM READS
/// THE FORM, AND THE TEST EMAIL PROVES WHY THAT MATTERS. `eventTypes.testEmail`
/// sends the STORED wording, so offering it beside unsaved edits invites somebody
/// to check a template they have just changed and be shown the old one. The web
/// disables the button while the tab is dirty for exactly this reason; a model
/// that holds no draft cannot be dirty at all.
///
/// ⛔ ARCHIVE AND DELETE ARE DIFFERENT OPERATIONS AND BOTH ARE OFFERED. Archiving
/// is `eventTypes.patch {archived: true}` and hides the event type while its
/// bookings stay addressable; `eventTypes.delete` removes the row and its booking
/// page. Only the delete confirms, which is the web's arrangement and is right:
/// archiving is reversible from the same menu.
///
/// ⚠️ THE ROW IS HELD AND REPLACED ON EVERY PATCH, so the menu's labels ("Turn
/// off" versus "Turn on") come from what the server last said rather than from
/// what this client assumed it did.
@MainActor
@Observable
final class SchedulingEventTypeActionsModel {
    private(set) var eventType: SchedulingEventType
    /// ⚠️ FOUR DIFFERENT WRITES LAND HERE AND EACH SUCCEEDS WITH ITS OWN WORDING,
    /// which ``SchedulingWriteState/done(_:)`` carries.
    private(set) var state: SchedulingWriteState = .idle
    /// ⚠️ True while the confirmation dialog should be up. The view binds it; the
    /// model owns it so a re-render cannot lose a pending destructive prompt.
    var confirmingDelete = false

    private let admin: SchedulingAdminRepository
    private let workspaceId: String
    private let onSaved: (SchedulingEventTypeChange) -> Void

    init(
        admin: SchedulingAdminRepository,
        workspaceId: String,
        eventType: SchedulingEventType,
        onSaved: @escaping (SchedulingEventTypeChange) -> Void
    ) {
        self.admin = admin
        self.workspaceId = workspaceId
        self.eventType = eventType
        self.onSaved = onSaved
    }

    var isActive: Bool {
        eventType.isActive != false
    }

    var isArchived: Bool {
        eventType.archived == true
    }

    var toggleTitle: String {
        isActive ? SchedulingWriteCopy.turnOff : SchedulingWriteCopy.turnOn
    }

    var archiveTitle: String {
        isArchived ? SchedulingWriteCopy.restore : SchedulingWriteCopy.archive
    }

    var busy: Bool {
        state.isWorking
    }

    func dismissNotice() {
        state = .idle
    }

    // MARK: - The writes

    /// Turn the booking page on or off.
    func toggleActive() async {
        let next = !isActive
        var changes = SchedulingEventTypeChanges()
        changes.isActive = next
        await patch(changes, notice: next ? SchedulingWriteCopy.turnedOn : SchedulingWriteCopy.turnedOff)
    }

    /// Archive or restore.
    func toggleArchived() async {
        let next = !isArchived
        var changes = SchedulingEventTypeChanges()
        changes.archived = next
        await patch(changes, notice: next ? SchedulingWriteCopy.archived : SchedulingWriteCopy.restored)
    }

    /// ⛔ THE ONE OP HERE THAT REMOVES SOMETHING, AND IT IS THE ONLY ONE BEHIND A
    /// CONFIRMATION. The caller sets ``confirmingDelete``; this runs on the
    /// dialog's destructive button.
    func delete() async {
        guard !state.isWorking else { return }
        confirmingDelete = false
        state = .working
        do {
            try await admin.deleteEventType(workspaceId: workspaceId, slug: eventType.slug)
            state = .done(SchedulingWriteCopy.eventTypeDeleted)
            onSaved(.deleted(slug: eventType.slug))
        } catch {
            state = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    /// Send one of the four templates to the calling member.
    ///
    /// ⛔ THERE IS NO RECIPIENT ARGUMENT AND THE ADDRESS COMES BACK IN THE ANSWER.
    /// The fork addresses the caller's own scheduler address deliberately, so the
    /// sentence names an address this client did not choose — which is the point
    /// worth showing, because it is often not the one somebody expects.
    ///
    /// ⚠️ `sent: false` IS A SUCCESSFUL RESPONSE REPORTING THAT NOTHING WAS SENT,
    /// and it is reported as a notice rather than as a failure: the request worked,
    /// the mail did not, and a failure strip offering "try again" would misdescribe
    /// which half is broken.
    func sendTestEmail(type: String) async {
        guard !state.isWorking else { return }
        state = .working
        do {
            let result = try await admin.sendEventTypeTestEmail(
                workspaceId: workspaceId,
                slug: eventType.slug,
                type: type
            )
            state = .done(
                result.sent
                    ? SchedulingWriteCopy.testEmailSent(to: result.to)
                    : SchedulingWriteCopy.testEmailNotSent
            )
        } catch {
            state = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    private func patch(_ changes: SchedulingEventTypeChanges, notice message: String) async {
        guard !state.isWorking else { return }
        state = .working
        do {
            let row = try await admin.patchEventType(
                workspaceId: workspaceId,
                slug: eventType.slug,
                changes: changes
            )
            eventType = row
            state = .done(message)
            onSaved(.saved(row))
        } catch {
            state = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }
}
