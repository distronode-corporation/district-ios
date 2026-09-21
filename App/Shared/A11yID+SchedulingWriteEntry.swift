/// Accessibility identifiers for the controls that OPEN a scheduling write.
///
/// ⛔ SEPARATE FROM THE THREE SHEET ENUMS BECAUSE THEY NAME A DIFFERENT THING.
/// `SchedulingWrites`, `SchedulingWritesB`, `SchedulingDeveloperWrites` and
/// `SchedulingCalendarWrites` name controls INSIDE a presented sheet; everything
/// here is the button on a READ screen that presents one. A UI test walking the
/// surface addresses this set first and never sees the others until it has
/// pressed one.
///
/// ⚠️ ONE LEVEL OF NESTING, for the reason `A11yID+SchedulingWrites.swift`
/// records: `.swiftlint.yml` warns at `nesting.type_level: 2` and `--strict`
/// turns that into an error.
extension A11yID {
    enum SchedulingWriteEntry {
        // Event types.
        static let eventTypeCreate = "district-scheduling-entry-event-type-create"
        static let eventTypeEdit = "district-scheduling-entry-event-type-edit"
        static let eventTypeActions = "district-scheduling-entry-event-type-actions"
        static let eventTypeHosts = "district-scheduling-entry-event-type-hosts"
        static let eventTypeQuestions = "district-scheduling-entry-event-type-questions"

        // Working hours.
        static let hoursEdit = "district-scheduling-entry-hours-edit"
        static let overridesEdit = "district-scheduling-entry-overrides-edit"

        // Bookings.
        static let bookingCancel = "district-scheduling-entry-booking-cancel"
        static let bookingReschedule = "district-scheduling-entry-booking-reschedule"
        static let bookingReassign = "district-scheduling-entry-booking-reassign"

        // Team.
        static let teamCreate = "district-scheduling-entry-team-create"
        static let teamEdit = "district-scheduling-entry-team-edit"
        static let teamMembers = "district-scheduling-entry-team-members"
        static let userArchive = "district-scheduling-entry-user-archive"

        // Settings.
        static let brandingEdit = "district-scheduling-entry-branding-edit"
        static let automationEdit = "district-scheduling-entry-automation-edit"
        static let profileEdit = "district-scheduling-entry-profile-edit"
        static let notificationsEdit = "district-scheduling-entry-notifications-edit"

        /// The bulk delete. ⚠️ The per-row delete is addressed through
        /// ``A11yID/SchedulingWritesB/recordingDeleteConfirm``, because it is a control
        /// inside the row rather than one that opens a sheet.
        static let recordingDeleteAll = "district-scheduling-entry-recording-delete-all"

        // Developer.
        static let keyCreate = "district-scheduling-entry-key-create"
        static let webhookCreate = "district-scheduling-entry-webhook-create"
        static let webhookEdit = "district-scheduling-entry-webhook-edit"

        // Calendar.
        static let caldavConnect = "district-scheduling-entry-caldav-connect"
        static let calendarSelect = "district-scheduling-entry-calendar-select"
    }
}
