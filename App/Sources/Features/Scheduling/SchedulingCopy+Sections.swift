import DistrictData
import Foundation

/// The wording for the hours, bookings, calendar, team, settings and developer
/// sections.
///
/// ⚠️ ONE FILE FOR SIX SECTIONS RATHER THAN SIX FILES, because every one of them is a
/// short table of labels and SwiftLint's 500-line file limit is comfortably met. The
/// overview and the event types have their own files because each carries a
/// derivation as well as a table.
extension SchedulingCopy {
    // MARK: - Working hours

    /// ⛔ "Not bookable" RATHER THAN A BLANK FOR A DAY WITH NO HOURS. An empty value beside
    /// a weekday is indistinguishable from a row that failed to load, which on an
    /// availability grid is the one confusion worth spending a word to avoid.
    static func dayHours(_ ranges: [SchedulingHoursRange]) -> String {
        guard !ranges.isEmpty else { return dayNotBookable }
        let show = SchedulingOverviewSummary.displayTime
        return ranges.map { hoursRange(show($0.start), show($0.end)) }.joined(separator: ", ")
    }

    // MARK: - Bookings

    /// ⛔ THE EMPTY SENTENCE DEPENDS ON THE VIEW, because "there are none" means different
    /// things per filter. Telling somebody looking at Cancelled to "share your booking
    /// page" would be advice for a problem they do not have.
    static func bookingsEmptyBody(_ view: SchedulingBookingView) -> String {
        switch view {
        case .upcoming:
            bookingsEmptyUpcoming
        case .past:
            bookingsEmptyPast
        case .cancelled:
            bookingsEmptyCancelled
        case .all:
            bookingsEmptyUpcoming
        }
    }

    // MARK: - Team

    static func memberSubtitle(email: String, role: String?) -> String {
        guard let role else { return email }
        return memberSubtitleWithRole(email, role)
    }

    // MARK: - Settings

    static func onOff(_ value: Bool) -> String {
        value ? on : off
    }
}
