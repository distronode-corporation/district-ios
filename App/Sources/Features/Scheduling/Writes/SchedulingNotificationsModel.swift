import DistrictData
import DistrictModel
import Foundation
import Observation

/// The seven `notify_*` preferences, which are the same `me.patch` op as the
/// profile and a separate form.
///
/// ⛔ A SEPARATE MODEL FROM ``SchedulingProfileModel`` THOUGH IT IS ONE OP, WHICH
/// IS THE WEB NOTIFICATIONS TAB'S OWN SPLIT. `me.patch` is sparse, so each
/// form sends only the keys it owns and the other form's fields are left alone —
/// which is what makes two forms over one op safe. ⛔ Merging them would mean one
/// save carrying twelve fields, and a stale draft in either half would overwrite
/// whatever the other half had just stored.
///
/// ⚠️ `notifyHostCancel` AND `notifyCancellation` ARE ONE WORD APART AND MEAN MAIL
/// TO TWO DIFFERENT PEOPLE — the host, and the attendee. That is why
/// ``SchedulingMeUpdate`` is a struct of labelled properties rather than twelve
/// positional optionals, and why the two groups are labelled on screen.
@MainActor
@Observable
final class SchedulingNotificationsModel {
    private(set) var state: SchedulingWriteState = .idle
    private(set) var confirmation: Bool
    private(set) var cancellation: Bool
    private(set) var reschedule: Bool
    private(set) var reminder: Bool
    private(set) var hostBooking: Bool
    private(set) var hostCancel: Bool
    private(set) var hostReschedule: Bool

    private let admin: SchedulingAdminRepository
    private let workspaceId: String
    private let onSaved: (SchedulingMe) -> Void

    init(
        admin: SchedulingAdminRepository,
        workspaceId: String,
        me: SchedulingMe,
        onSaved: @escaping (SchedulingMe) -> Void
    ) {
        self.admin = admin
        self.workspaceId = workspaceId
        self.onSaved = onSaved
        confirmation = me.notifyConfirmation
        cancellation = me.notifyCancellation
        reschedule = me.notifyReschedule
        reminder = me.notifyReminder
        hostBooking = me.notifyHostBooking
        hostCancel = me.notifyHostCancel
        hostReschedule = me.notifyHostReschedule
    }

    var busy: Bool {
        state.isWorking
    }

    func editConfirmation(_ value: Bool) {
        confirmation = value
        clearFailure()
    }

    func editCancellation(_ value: Bool) {
        cancellation = value
        clearFailure()
    }

    func editReschedule(_ value: Bool) {
        reschedule = value
        clearFailure()
    }

    func editReminder(_ value: Bool) {
        reminder = value
        clearFailure()
    }

    func editHostBooking(_ value: Bool) {
        hostBooking = value
        clearFailure()
    }

    func editHostCancel(_ value: Bool) {
        hostCancel = value
        clearFailure()
    }

    func editHostReschedule(_ value: Bool) {
        hostReschedule = value
        clearFailure()
    }

    /// ⚠️ ALL SEVEN, ALWAYS. A Bool has no "untouched" value to omit, and sending
    /// only the ones that changed would need this model to remember what it was
    /// given — state whose only purpose would be to save six keys on a body that
    /// is already small.
    func save() async {
        guard !busy else { return }
        var update = SchedulingMeUpdate()
        update.notifyConfirmation = confirmation
        update.notifyCancellation = cancellation
        update.notifyReschedule = reschedule
        update.notifyReminder = reminder
        update.notifyHostBooking = hostBooking
        update.notifyHostCancel = hostCancel
        update.notifyHostReschedule = hostReschedule
        state = .working
        do {
            let fresh = try await admin.updateMe(workspaceId: workspaceId, update)
            state = .done(SchedulingSettingsWriteCopy.notificationsDone)
            onSaved(fresh)
        } catch {
            state = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    private func clearFailure() {
        if case .failed = state {
            state = .idle
        }
    }
}
