import DistrictData
import DistrictModel
import Foundation
import Observation

/// The slot list behind the reschedule picker.
///
/// ⚠️ ``idle`` IS NOT ``ready([])``. Nothing has been asked for yet, which is a
/// different sentence from "nothing is free that day" — and on this sheet the
/// second one is what tells an operator to try another date.
enum SchedulingRescheduleSlotsState {
    case idle
    case loading
    case ready([SchedulingSlot])
    case failed(FailureText)
}

/// Moving one booking to a new start, against the same slot list the public
/// booking page computes.
///
/// ⛔ IT ASKS FOR EXACTLY ONE DAY — `from` AND `to` ARE THE SAME DATE — which is
/// the web bookings table's own query and not a simplification. A window would answer
/// every slot in it and turn one picker into two, and the fork refuses anything
/// but `YYYY-MM-DD` for either bound.
///
/// ⛔ AND `tz` IS ALWAYS SENT. Leaving it nil does not mean "the device's zone", it
/// means whatever the scheduler decides — so a sheet rendering the answer as local
/// time without having asked would be guessing. The zone comes from the signed-in
/// scheduler profile, which is the zone the operator's own windows are published
/// in.
///
/// ⛔ NO END TIME IS SENT AND NONE MAY BE. The far end recomputes the end from the
/// event type's duration, which is what keeps a rescheduled booking consistent
/// with the event type it belongs to.
///
/// ⚠️ A `slot_taken` REFUSAL ARRIVES AS A **200** and is the one failure this
/// model recovers from by RE-READING rather than by offering a retry: the slot is
/// gone and the identical request stays refused. The web does the same re-fetch.
@MainActor
@Observable
final class SchedulingBookingRescheduleModel {
    private(set) var state: SchedulingWritesBState = .idle
    private(set) var slots: SchedulingRescheduleSlotsState = .idle
    private(set) var day: Date
    private(set) var selectedStart: String?
    /// ⚠️ "Pick a time." — a validation sentence rather than a failure, for
    /// ``SchedulingBookingCancelModel/reasonRejected``'s reason.
    private(set) var selectionRejected: String?

    private let admin: SchedulingAdminRepository
    private let workspaceId: String
    private let bookingId: String
    private let eventTypeSlug: String
    private let timezone: String
    private let onSaved: (SchedulingBooking) -> Void

    /// - Parameter eventTypeSlug: ⛔ REQUIRED, AND THE CALLER MUST NOT OFFER THIS
    ///   SHEET WITHOUT ONE. `SchedulingBooking.eventTypeSlug` is Optional and a
    ///   booking that has lost its event type cannot be rescheduled at all — the
    ///   slots op is keyed by slug. The web hides the action for exactly that row.
    /// - Parameter timezone: an IANA identifier. See the ⛔ on the type.
    init(
        admin: SchedulingAdminRepository,
        workspaceId: String,
        bookingId: String,
        eventTypeSlug: String,
        timezone: String,
        startingFrom: Date = Date(),
        onSaved: @escaping (SchedulingBooking) -> Void
    ) {
        self.admin = admin
        self.workspaceId = workspaceId
        self.bookingId = bookingId
        self.eventTypeSlug = eventTypeSlug
        self.timezone = timezone
        self.onSaved = onSaved
        day = startingFrom
    }

    var busy: Bool {
        state.isWorking
    }

    var availableSlots: [SchedulingSlot] {
        guard case let .ready(rows) = slots else { return [] }
        return rows
    }

    /// ⚠️ The tz the picker and the labels must both use. A slot rendered in the
    /// device's zone against a list fetched in the profile's zone is two clocks on
    /// one sheet.
    var displayTimeZone: TimeZone {
        TimeZone(identifier: timezone) ?? .current
    }

    var dayKey: String {
        Self.dayFormatter(displayTimeZone).string(from: day)
    }

    /// ⛔ CLEARS THE SELECTION, ALWAYS. A start chosen on Tuesday is not a start on
    /// Wednesday, and leaving it set is how a confirm button stays enabled against
    /// a slot that is no longer on screen.
    func editDay(_ value: Date) {
        day = value
        selectedStart = nil
        selectionRejected = nil
    }

    func select(_ slot: SchedulingSlot) {
        selectedStart = slot.start
        selectionRejected = nil
    }

    /// Read the day's bookable windows.
    ///
    /// ⚠️ AN EMPTY ANSWER IS A LEGITIMATE 200. An unknown slug answers an empty
    /// list rather than a 404, so an empty day is not evidence the slug was
    /// understood — which is why the caller is required to pass a slug the booking
    /// itself carried.
    func loadSlots() async {
        slots = .loading
        selectedStart = nil
        let key = dayKey
        do {
            let answer = try await admin.eventTypeSlots(
                workspaceId: workspaceId,
                slug: eventTypeSlug,
                from: key,
                to: key,
                tz: timezone
            )
            slots = .ready(answer.slots)
        } catch {
            slots = .failed(SchedulingWritesBFailure.text(for: error))
        }
    }

    func submit() async {
        guard !busy else { return }
        guard let start = selectedStart else {
            selectionRejected = SchedulingBookingWriteCopy.reschedulePickTime
            return
        }
        state = .working
        do {
            let booking = try await admin.rescheduleBooking(
                workspaceId: workspaceId,
                bookingId: bookingId,
                startAt: start
            )
            state = .done(SchedulingBookingWriteCopy.rescheduleDone(label(for: booking.startAt)))
            onSaved(booking)
        } catch {
            state = .failed(SchedulingWritesBFailure.text(for: error))
            // ⛔ THE SLOT LIST IS NOW KNOWN TO BE STALE, so it is re-read rather
            // than left on screen with the taken time still tappable. Only for
            // this one code: every other refusal leaves the list as true as it was.
            if SchedulingWritesBFailure.isSlotTaken(error) {
                await loadSlots()
            }
        }
    }

    /// One slot's label, in the zone the slots were asked for.
    ///
    /// ⚠️ AN UNPARSEABLE INSTANT FALLS BACK TO THE RAW STRING RATHER THAN TO AN
    /// EMPTY LABEL. `start` is the value that gets sent back verbatim, so a tile an
    /// operator cannot read is still better than a tile they cannot tell apart.
    func label(for instant: String) -> String {
        guard let date = Self.parse(instant) else { return instant }
        let formatter = DateFormatter()
        formatter.timeZone = displayTimeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// ⚠️ TWO FORMATTERS, BECAUSE RFC3339 FRACTIONAL SECONDS ARE OPTIONAL AND
    /// `ISO8601DateFormatter` PARSES ONLY WHAT ITS OPTIONS SAY. A fork that starts
    /// emitting milliseconds would otherwise silently stop producing labels.
    static func parse(_ instant: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: instant) {
            return date
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: instant)
    }

    /// ⛔ `en_US_POSIX`, NOT THE DEVICE LOCALE. `yyyy-MM-dd` under a non-Gregorian
    /// calendar or a Buddhist-era locale produces a year the fork refuses, and the
    /// refusal is an `invalid_params` naming `from`.
    static func dayFormatter(_ zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
