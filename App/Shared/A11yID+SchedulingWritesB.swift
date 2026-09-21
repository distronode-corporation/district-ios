/// Identifiers for the bookings, team, settings and recordings write surfaces.
///
/// ⛔ A SEPARATE FILE FROM `A11yID.swift`, AND A SEPARATE NAMESPACE FROM THE OTHER
/// WRITE SURFACES'. Each adds cases to one enum; an extension per surface is the only
/// shape where work on one never touches a file the other is editing.
///
/// ⛔ ONE NESTING LEVEL, FLAT CONSTANTS. `.swiftlint.yml` sets
/// `nesting.type_level.warning: 2` and `--strict` promotes it, so a
/// `A11yID.SchedulingWritesB.Bookings.cancel` grouping would be a build failure
/// rather than a style note.
///
/// ⚠️ NO ANDROID COUNTERPART EXISTS FOR ANY OF THESE. The scheduling admin is
/// iOS-first, so unlike the identifiers in `A11yID.swift` these are new strings
/// rather than copies — and the day Android grows the surface, these are the names
/// it should take.
extension A11yID {
    enum SchedulingWritesB {
        // Bookings
        static let bookingCancelSheet = "district-scheduling-booking-cancel"
        static let bookingCancelReason = "district-scheduling-booking-cancel-reason"
        static let bookingCancelConfirm = "district-scheduling-booking-cancel-confirm"
        static let bookingRescheduleSheet = "district-scheduling-booking-reschedule"
        static let bookingRescheduleDay = "district-scheduling-booking-reschedule-day"
        static let bookingRescheduleConfirm = "district-scheduling-booking-reschedule-confirm"
        /// ⚠️ Suffixed with the slot's own `start` through ``A11yID/row(_:_:)``, so
        /// a test addresses a TIME rather than the third tile in a list whose
        /// length depends on somebody's calendar.
        static let bookingRescheduleSlot = "district-scheduling-booking-reschedule-slot"
        static let bookingReassignSheet = "district-scheduling-booking-reassign"
        static let bookingReassignHost = "district-scheduling-booking-reassign-host"
        static let bookingReassignConfirm = "district-scheduling-booking-reassign-confirm"
        static let bookingRegenerateNotes = "district-scheduling-booking-regenerate-notes"

        // Teams
        static let teamCreateSheet = "district-scheduling-team-create"
        static let teamNameField = "district-scheduling-team-name"
        static let teamCreateConfirm = "district-scheduling-team-create-confirm"
        static let teamRenameConfirm = "district-scheduling-team-rename-confirm"
        static let teamDeleteConfirm = "district-scheduling-team-delete-confirm"
        static let teamMembersSheet = "district-scheduling-team-members"
        static let teamMemberAdd = "district-scheduling-team-member-add"
        static let teamMemberPicker = "district-scheduling-team-member-picker"
        /// Suffixed with the scheduler user id.
        static let teamMemberPriority = "district-scheduling-team-member-priority"
        /// Suffixed with the scheduler user id.
        static let teamMemberRemove = "district-scheduling-team-member-remove"
        static let userArchiveSheet = "district-scheduling-user-archive"
        static let userArchiveConfirm = "district-scheduling-user-archive-confirm"

        // Settings
        static let profileSheet = "district-scheduling-profile"
        static let profileName = "district-scheduling-profile-name"
        static let profileSave = "district-scheduling-profile-save"
        static let profileAvatarPick = "district-scheduling-profile-avatar-pick"
        static let profileAvatarRemove = "district-scheduling-profile-avatar-remove"
        static let notificationsSave = "district-scheduling-notifications-save"
        static let brandingSheet = "district-scheduling-branding"
        static let brandingBusinessName = "district-scheduling-branding-business-name"
        static let brandingSave = "district-scheduling-branding-save"
        static let brandingLogoPick = "district-scheduling-branding-logo-pick"
        static let brandingLogoRemove = "district-scheduling-branding-logo-remove"
        static let brandingBannerPick = "district-scheduling-branding-banner-pick"
        static let brandingBannerRemove = "district-scheduling-branding-banner-remove"
        static let automationSheet = "district-scheduling-automation"
        static let automationRecordings = "district-scheduling-automation-recordings"
        static let automationNotetaker = "district-scheduling-automation-notetaker"
        static let automationAssistant = "district-scheduling-automation-assistant"
        static let automationInstructions = "district-scheduling-automation-instructions"
        static let automationSave = "district-scheduling-automation-save"

        // Recordings
        static let recordingDeleteConfirm = "district-scheduling-recording-delete-confirm"
        static let recordingDeleteAllSheet = "district-scheduling-recording-delete-all"
        static let recordingDeleteAllField = "district-scheduling-recording-delete-all-field"
        static let recordingDeleteAllConfirm = "district-scheduling-recording-delete-all-confirm"
    }
}
