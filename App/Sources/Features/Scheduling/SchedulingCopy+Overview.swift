import Foundation

/// The overview register's wording.
///
/// ⛔ THE EMPTY-ROW SENTENCES ARE THE WEB'S REMEDIES REWRITTEN AS STATEMENTS. The browser
/// renders each as a LINK into the page that can create the thing ("Create an event type",
/// "Connect a calendar", "Set your hours"); those are writes, which this stage does not
/// have, so a link would lead to a read-only screen that cannot do what its label promises.
/// The sentence says the same fact without the false offer, and the write stage turns each
/// one back into a destination.
extension SchedulingCopy {
    static let deskEyebrow = "Your booking desk"

    static let deskBookingPage = "Booking page"
    static let deskCalendar = "Calendar"
    static let deskHours = "Working hours"
    static let deskEventTypes = "Event types"
    static let deskNextBooking = "Next booking"

    static let deskNoEventTypes = "No event types yet, so there is nothing to book."

    /// ⚠️ A DIFFERENT SENTENCE FROM "no event types", BECAUSE IT IS A DIFFERENT FACT. A
    /// tenancy still provisioning has no public host, so there is no address to publish
    /// even for event types that exist. Collapsing the two would tell somebody to create
    /// an event type they may already have.
    static let deskNoHost = "The booking address is not ready yet."

    static let deskNoCalendar = "No calendar is connected, so nothing is checked for conflicts."

    static let deskNoHours = "Not bookable on any day yet."

    static let deskNoBookings = "None yet."

    static let comingUpEyebrow = "Coming up"

    /// ⚠️ THE WEB OFFERS A "Copy link" BUTTON BESIDE THIS; the hub already carries Copy
    /// and Share for the booking link, so repeating it here would be a third copy of one
    /// affordance on two screens.
    static let comingUpEmpty = "No bookings yet. Share your booking page and they will appear here."

    static let loadingBookings = "Loading bookings…"

    /// ⛔ THE ZONE IS NAMED ON EVERY SCREEN THAT RENDERS A TIME, AND IT IS THE OPERATOR'S
    /// SCHEDULER PROFILE ZONE RATHER THAN THE DEVICE'S. Somebody reading a booking on a
    /// phone in another country needs to know which clock they are looking at; without
    /// this line the hour is ambiguous exactly when it matters most. See the ⛔ on
    /// ``SchedulingClock``.
    static func timesIn(_ zone: String) -> String {
        "Times in \(zone)"
    }

    /// ⛔ `Unknown` RATHER THAN A BLANK OR A GUESS, matching the web. A stamp that will not
    /// parse is a corrupt row, and rendering today's date for it would be a lie the reader
    /// cannot detect.
    static let unknownTime = "Unknown"
}
