import DistrictModel
import SwiftUI

/// The one place a ``SchedulingSection`` becomes a screen.
///
/// ⛔ SPLIT OUT OF ``RouteDestinations`` FOR THE LINE BUDGET, EXACTLY AS
/// `helpDestination` WAS. That switch is at SwiftLint's 60-line ceiling and twelve more
/// arms would not fit; what matters is that it stays EXHAUSTIVE, so a new `Route` case
/// still fails to compile there. This function is the same contract one level down: a new
/// ``SchedulingSection`` case fails to compile HERE until somebody decides what it shows.
///
/// ⛔ AND THERE IS NO PLACEHOLDER ARM, WHICH IS THE RULE ``RouteDestinations`` STATES AND
/// THIS FILE INHERITS. Every arm below renders a real screen over a real read;
/// `PlaceholderView`'s own header records that it may not be reachable from a build that
/// goes to external testers (App Store Review Guideline 2.1), and nine rows on a hub are
/// nine taps from the Overview.
///
/// ⚠️ THE ROLE IS CARRIED TO EVERY SECTION AND READ BY EXACTLY ONE. `recordings.list` is
/// `viewer` while the download beside it is `agency`/`client`, so
/// ``SchedulingRecordingsView`` gates one affordance on it. The other eight take it and
/// ignore it, deliberately: a signature that varied per section would have to be
/// remembered per call site, and the write stage gives all of them something to gate.
enum SchedulingDestinations {
    @MainActor
    @ViewBuilder
    static func view(
        for section: SchedulingSection,
        container: AppContainer,
        workspaceId: String,
        role: WorkspaceRole?
    ) -> some View {
        switch section {
        case .hub:
            SchedulingHubView(container: container, workspaceId: workspaceId, role: role)

        case .overview:
            SchedulingOverviewView(container: container, workspaceId: workspaceId, role: role)

        case .eventTypes:
            SchedulingEventTypesView(container: container, workspaceId: workspaceId, role: role)

        // ⛔ THE SLUG IS THE SERVER'S KEY AND IS NEVER REBUILT FROM A DISPLAY NAME.
        // `eventTypes.get` takes a slug; deriving one from a title would be this client
        // inventing an address.
        case let .eventType(slug):
            SchedulingEventTypeView(
                container: container,
                workspaceId: workspaceId,
                role: role,
                slug: slug
            )

        case .hours:
            SchedulingHoursView(container: container, workspaceId: workspaceId, role: role)

        case .bookings:
            SchedulingBookingsView(container: container, workspaceId: workspaceId, role: role)

        case let .booking(id):
            SchedulingBookingDetailView(
                container: container,
                workspaceId: workspaceId,
                role: role,
                bookingId: id
            )

        case .calendar:
            SchedulingCalendarView(container: container, workspaceId: workspaceId, role: role)

        case .team:
            SchedulingTeamView(container: container, workspaceId: workspaceId, role: role)

        // ⛔ THE ONE SECTION WHOSE ROLE IS LOAD-BEARING. See the ⚠️ on this type.
        case .recordings:
            SchedulingRecordingsView(container: container, workspaceId: workspaceId, role: role)

        case .settings:
            SchedulingSettingsView(container: container, workspaceId: workspaceId, role: role)

        case .developer:
            SchedulingDeveloperView(container: container, workspaceId: workspaceId, role: role)
        }
    }
}
