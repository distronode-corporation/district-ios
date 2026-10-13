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
    // MARK: - Reschedule

    /// ⚠️ NAMES THE NEW TIME WHEN ONE CAN BE FORMATTED. The web does the same, and
    /// the reason is checkability: "Booking moved" is true of a move to the wrong
    /// day as well as the right one.
    static func rescheduleDone(_ when: String) -> String {
        when.isEmpty ? rescheduleDone : rescheduleDoneAt(when)
    }
}
