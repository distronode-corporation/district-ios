import DistrictNetwork
import Foundation

/// The sections under the scheduling hub, and the two rows that open onto a screen
/// of their own.
///
/// ⛔ THE SECTIONS ARE CHILDREN OF THE HUB rather than siblings of it, exactly as
/// ``SettingsSection`` is, which is what makes a back press from a booking land on
/// the bookings list and the press after it land on the hub. One ``Route/scheduling``
/// case covers the whole family.
///
/// ⛔ THE TWO DRILL-DOWNS ARE CASES OF THIS ENUM RATHER THAN `Route` CASES OF THEIR
/// OWN, WHICH IS WHERE THIS TYPE DIVERGES FROM ``SettingsSection``. That one is a
/// `String` enum because every settings section is a leaf; an event type and a booking
/// are each addressed by an identifier, so the alternative was two more `Route` cases
/// and two more arms in ``RouteDestinations``, which is at SwiftLint's 60-line
/// ceiling. The cost is that this cannot be `CaseIterable` or `RawRepresentable`, and
/// ``listed`` plus ``pathSegment`` carry what those would have given.
///
/// ⛔ AND BOTH DRILL-DOWNS ARE SAFE TO RESTORE FROM A `NavigationPath`, which is the
/// property that permits them to be destinations at all. Arriving at either one runs
/// an idempotent GET and nothing else — the same argument ``Route/deskTicket`` makes,
/// and the opposite of ``Route/dialer``, whose absent in-call destination exists so a
/// restored back stack cannot place a second billable call.
///
/// ⚠️ THE SLUG AND THE ID ARE THE SERVER'S OWN AND ARE NEVER REBUILT. An event type is
/// addressed by SLUG because `eventTypes.get` takes one (`SchedulingEventType/slug`),
/// and a booking by ID because `bookings.answers` does; carrying the other half of
/// either pair would mean deriving the server's key from a display value.
enum SchedulingSection: Hashable, Sendable {
    /// The hub itself: the tenancy card, Enable, and the list of the nine below.
    case hub

    /// The register the web serves at the scheduling ROOT: four reads summarised.
    case overview

    case eventTypes

    /// One event type, read-only. ⚠️ An INSPECTOR, not an editor; see the ⛔ on
    /// ``SchedulingEventTypeView``.
    case eventType(slug: String)

    case hours

    case bookings

    /// One booking, with its answers, notes and transcript.
    case booking(id: String)

    case calendar

    case team

    case recordings

    case settings

    case developer
}

extension SchedulingSection {
    /// The nine rows the hub draws, in the web console's own order.
    ///
    /// ⛔ THE ORDER MIRRORS THE WEB SIDEBAR. An operator who has used the dashboard
    /// should find the same thing in the same place; a phone that reordered them by how
    /// often they are opened would be optimising the wrong number. ``SettingsHubView``
    /// records the identical rule for its own list.
    ///
    /// ⚠️ THE TWO DRILL-DOWNS ARE ABSENT AND MUST STAY ABSENT. They have no hub row
    /// because neither can be addressed without an identifier the hub does not hold, and
    /// a row that navigated to a guessed slug would be a link to a failure screen.
    static let listed: [SchedulingSection] = [
        .overview,
        .eventTypes,
        .hours,
        .bookings,
        .calendar,
        .team,
        .recordings,
        .settings,
        .developer,
    ]

    /// The URL segment under `/dashboard/district/scheduling` that names this section.
    ///
    /// ⛔ THE STRINGS ARE THE WEB DASHBOARD'S PATH SEGMENTS VERBATIM, HYPHENS AND ALL,
    /// so a link copied out of a browser resolves here; `eventTypes`
    /// would be a segment no page answers. ⚠️ ``hub`` and the two drill-downs answer nil
    /// rather than a segment: the hub IS the bare path and has no segment of its own,
    /// and neither drill-down has a published URL to copy.
    var pathSegment: String? {
        switch self {
        case .hub, .eventType, .booking: nil
        case .overview: "overview"
        case .eventTypes: "event-types"
        case .hours: "hours"
        case .bookings: "bookings"
        case .calendar: "calendar"
        case .team: "team"
        case .recordings: "recordings"
        case .settings: "settings"
        case .developer: "developer"
        }
    }

    /// The section a URL's second segment names, or ``hub`` for one this app has no
    /// screen for.
    ///
    /// ⛔ AN UNKNOWN SEGMENT IS THE HUB AND IS NEVER A REFUSAL, WHICH IS THE OPPOSITE
    /// CALL FROM ``AppLinkResolver``'s TOP-LEVEL ONE and correct for the opposite
    /// reason. There, a first segment this app cannot draw becomes
    /// ``AppLinkOutcome/openInBrowser``, because the page exists on the web and landing
    /// somewhere else would be showing the user something they did not ask for. Here the
    /// claim is already narrowed to scheduling, so the hub IS the surface the URL named
    /// — one level up, with every section one tap away — and bouncing to a browser would
    /// leave the app for a page it can draw.
    ///
    /// ⚠️ IT TAKES AN ALREADY-LOWERCASED SEGMENT. ``AppLinkResolver/detailId(for:segments:)``
    /// folds it, because a shared link is retyped by humans; folding again here would be
    /// a second copy of that rule for the same value.
    static func forPathSegment(_ segment: String?) -> SchedulingSection {
        guard let segment else { return .hub }
        return listed.first { $0.pathSegment == segment } ?? .hub
    }
}

extension SchedulingSection {
    /// The lowest District role the server will accept every READ on this section from.
    ///
    /// ⛔ IT IS THE HIGHEST BAR AMONG THE SECTION'S READS AND NOT ITS FIRST ONE. A screen
    /// whose four reads are three `viewer`s and one `client` is a screen a viewer cannot
    /// fill, so the maximum is the only honest summary; taking the first would draw a row
    /// that opens onto a partial failure.
    ///
    /// ⚠️ EVERY SECTION ANSWERS `viewer` TODAY, AND THAT IS A MEASUREMENT RATHER THAN A
    /// SHORTCUT. Each value below is the `SchedulingAdminOp/minRole` of the ops the
    /// section's model actually sends, checked against `SchedulingAdminOp+Access.swift`:
    /// the read half of the catalog is `viewer` throughout, because the server's rule is
    /// "reads are viewer, writes are client". This property exists so that a WRITE
    /// surface has one place to disagree with that — and so that the day it does, the hub
    /// drops the row instead of offering a screen whose first request answers 403.
    ///
    /// ⛔ THE ONE PLACE THE RULE ALREADY BITES IS NOT HERE: `recordings.list` is `viewer`
    /// while the recording DOWNLOAD beside it is `agency`/`client`. That is an affordance
    /// inside a section rather than a bar on reaching it, so it is gated on the row's own
    /// control (see ``SchedulingRecordingsView``) and must not be lifted to this property
    /// — doing so would hide the consent evidence from the role most likely to be asked
    /// to check it.
    var minReadRole: SchedulingAdminRole {
        switch self {
        case .hub, .overview, .eventTypes, .eventType, .hours, .bookings, .booking,
             .calendar, .team, .recordings, .settings, .developer:
            .viewer
        }
    }
}
