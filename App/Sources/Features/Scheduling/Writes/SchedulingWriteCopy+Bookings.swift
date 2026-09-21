import Foundation

/// Every sentence the four booking writes put on screen.
///
/// ⛔ A NAMESPACE OF ITS OWN RATHER THAN AN EXTENSION ON A SHARED
/// `SchedulingWriteCopy`, THOUGH THE FILE IS NAMED AS IF IT WERE ONE. Each write
/// area owns its own enum, so no two files can both declare a shared base type and
/// collide in a redeclaration error. The file name keeps the intended shape; the
/// type name keeps the build.
///
/// ⛔ PORTED FROM THE WEB BOOKINGS TABLE, NOT AUTHORED. Two clients wording the same
/// confirmation differently is how an operator ends up believing the phone does
/// something the browser does not — and these particular sentences say what the
/// ATTENDEE receives, which is the part of a cancellation or a reschedule the
/// operator cannot see afterwards.
enum SchedulingBookingWriteCopy {
    // MARK: - Cancel

    static let cancelTitle = "Cancel this booking?"
    static let cancelBody = "The attendee gets a cancellation email."
    static let cancelReasonLabel = "Reason"
    /// ⚠️ "Optional" IS LOAD-BEARING. The catalog marks `reason` optional and the
    /// web omits the key entirely when it is blank, so a required-looking field
    /// would invent a step.
    static let cancelReasonHint = "Optional. It goes in the email."
    /// ⚠️ THE CATALOG'S OWN CEILING (`z.string().max(1000)`). The web does not
    /// check it and lets zod refuse; see ``SchedulingBookingCancelModel/submit()``
    /// for why this client does.
    static let cancelReasonTooLong = "That reason is longer than 1000 characters."
    static let cancelKeep = "Keep it"
    static let cancelConfirm = "Cancel booking"
    static let cancelDone = "Booking cancelled"

    // MARK: - Reschedule

    static let rescheduleTitle = "Reschedule this booking?"
    static let rescheduleBody = "The attendee gets an email with the new time."
    static let rescheduleDayLabel = "Day"
    static let rescheduleTimeLabel = "Time"
    static let rescheduleCancel = "Cancel"
    static let rescheduleConfirm = "Move booking"
    /// Shown when the day resolved but nothing in it is bookable.
    static let rescheduleNoSlots = "Nothing free that day. Try another."
    /// ⚠️ A VALIDATION SENTENCE, NOT A FAILURE. It never reaches
    /// ``SchedulingWritesBFailure`` because no request is spent on it.
    static let reschedulePickTime = "Pick a time."
    static let rescheduleDone = "Booking moved"

    /// ⚠️ NAMES THE NEW TIME WHEN ONE CAN BE FORMATTED. The web does the same, and
    /// the reason is checkability: "Booking moved" is true of a move to the wrong
    /// day as well as the right one.
    static func rescheduleDone(_ when: String) -> String {
        when.isEmpty ? rescheduleDone : "Booking moved to \(when)"
    }

    // MARK: - Reassign

    static let reassignTitle = "Reassign this booking?"
    static let reassignBody = "The booking keeps its time. Both hosts get an email about the change."
    static let reassignHostLabel = "New host"
    static let reassignHostPlaceholder = "Choose a host"
    static let reassignCancel = "Cancel"
    static let reassignConfirm = "Change host"
    static let reassignDone = "Host changed"
    /// ⚠️ Every other scheduler user is archived or is already the host.
    static let reassignNoHosts = "No other host can take it."

    // MARK: - Notes

    /// ⛔ NO CONFIRMATION, MATCHING THE WEB, AND THAT IS A DELIBERATE OMISSION
    /// RATHER THAN A GAP IN THE PORT. Regenerating notes destroys nothing: it
    /// queues a rewrite of a summary the far end can produce again, so a dialog
    /// would be ceremony in front of a safe button.
    static let regenerate = "Regenerate notes"
    /// ⛔ SAYS "ASKED FOR", NOT "WRITTEN". `bookings.notes.regenerate` returns as
    /// soon as the work is QUEUED — `status` is ordinarily `pending` and `content`
    /// is still the PREVIOUS text — so a sentence claiming new notes exist would be
    /// wrong for as long as the job takes. The web renders the response body and
    /// never renders its `status`; this client says what was actually achieved.
    static let regenerateDone = "Notes queued. They replace the old ones when they are written."
}
