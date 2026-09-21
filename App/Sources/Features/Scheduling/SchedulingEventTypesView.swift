import DistrictData
import DistrictModel
import Observation
import SwiftUI

/// Every event type in the tenancy: one page a customer can book, per row.
///
/// ⚠️ UNPAGED, BECAUSE THE OP IS. `eventTypes.list` takes no window and answers the whole
/// list; there is no offset to advance and nothing to scroll into. That is the fork's
/// shape rather than a simplification here.
@MainActor
@Observable
final class SchedulingEventTypesModel {
    private(set) var state: SchedulingSectionState<[SchedulingEventType]> = .loading

    /// ⛔ NEEDED TO SAY WHETHER A ROW'S BOOKING PAGE IS REACHABLE, AND NOT TO BUILD ONE
    /// SPECULATIVELY. Without a public host the column says "Not public", which is the
    /// truth for a tenancy that is not live; with one it is a real address.
    private(set) var publicHost: String?

    private let repository: SchedulingAdminRepository
    private let scheduling: SchedulingRepository
    private let workspaceId: String

    /// ⛔ THE DESIGNATED INITIALISER TAKES THE REPOSITORIES AND THE CONTAINER ONE
    /// DELEGATES TO IT, WHICH IS THE ONLY TEST SEAM ON THIS SURFACE. ``AppContainer``
    /// builds its own ``URLSessionHTTPTransport`` in `init`, so a test cannot hand it a
    /// fake; taking the collaborators directly lets `DistrictAITests` drive a real
    /// repository over a stub transport, which exercises the envelope walk rather than
    /// skipping it. ⚠️ Production still constructs through the container, so both
    /// collaborators remain the one shared ``ApiClient``.
    init(
        repository: SchedulingAdminRepository,
        scheduling: SchedulingRepository,
        workspaceId: String
    ) {
        self.repository = repository
        self.scheduling = scheduling
        self.workspaceId = workspaceId
    }

    convenience init(container: AppContainer, workspaceId: String) {
        self.init(
            repository: container.schedulingAdmin,
            scheduling: container.scheduling,
            workspaceId: workspaceId
        )
    }

    func load() async {
        state = .loading
        if case let .success(status) = await scheduling.status(workspaceId: workspaceId) {
            publicHost = status.tenant?.publicHost
        }
        do {
            state = try await .ready(repository.listEventTypes(workspaceId: workspaceId))
        } catch {
            state = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    /// One row, already formatted.
    struct Row: Identifiable {
        let id: String
        let slug: String
        let name: String
        let duration: String
        let interval: String
        let location: String
        let state: SchedulingStatusLabel
        let bookingPage: String
    }

    var rows: [Row] {
        guard let items = state.value else { return [] }
        return items.map { item in
            Row(
                id: item.id,
                slug: item.slug,
                name: item.name,
                duration: SchedulingBookingFormat.minutesLabel(item.durationMinutes),
                interval: SchedulingBookingFormat.minutesLabel(item.slotIntervalMinutes),
                location: SchedulingCopy.locationLabel(item.locationType),
                state: Self.stateLabel(item),
                bookingPage: bookingPage(for: item)
            )
        }
    }

    /// ⛔ ARCHIVED WINS OVER INACTIVE. An archived event type is also inactive, so
    /// reporting "Inactive" would be true and useless — it is the archive that explains
    /// why, and it is the archive somebody has to undo.
    static func stateLabel(_ item: SchedulingEventType) -> SchedulingStatusLabel {
        if item.archived == true {
            return SchedulingStatusLabel(label: "Archived", kind: .info)
        }
        if item.isActive == false {
            return SchedulingStatusLabel(label: "Inactive", kind: .stopped)
        }
        return SchedulingStatusLabel(label: "Active", kind: .success)
    }

    /// ⛔ "Not public" WHENEVER THE HOST IS UNKNOWN OR THE ROW IS NOT LIVE, AND NEVER A
    /// FABRICATED URL. Publishing an address for a page that does not answer is the one
    /// mistake this column can make that a customer would discover.
    private func bookingPage(for item: SchedulingEventType) -> String {
        guard let publicHost, !publicHost.isEmpty,
              item.archived != true, item.isActive != false, item.isPublic != false
        else { return SchedulingCopy.notPublic }
        return SchedulingOverviewSummary.bookingUrlFor(publicHost: publicHost, slug: item.slug)
    }

    // MARK: - Writes

    // ⛔ THE WEB'S ACTIONS MENU IS NOT HERE: "Turn on"/"Turn off" (`eventTypes.patch`),
    // "Archive"/"Restore" (also `patch`) and "Delete" (`eventTypes.delete`), plus the
    // "Create event type" button in the header. All four are `client`-level, so the
    // control must be gated on ``WorkspaceRole/allowsMutation(_:)`` AND the row's own
    // state — and Delete needs a confirmation, because an event type with bookings behind
    // it is not something to remove on one tap.
    //
    // ⚠️ THE SEAM IS THE ROW: ``Row`` already carries the slug, which is what all three
    // mutations address. Nothing about this model has to change shape for them.
}

struct SchedulingEventTypesView: View {
    @State private var model: SchedulingEventTypesModel

    /// ⛔ HELD ON THE VIEW BECAUSE THE ROW BUILDS A `Route`, AND A ROUTE MUST BE
    /// SELF-DESCRIBING. Reading them back off the model would work and would also put the
    /// navigation vocabulary inside a type whose job is the read; see the ⛔ at the top of
    /// ``Route`` for why every destination carries its own tenant and role.
    private let workspaceId: String
    private let role: WorkspaceRole?

    /// ⚠️ HELD BESIDE THE MODEL RATHER THAN REACHED THROUGH IT. The create sheet's
    /// model is built at the moment the button is pressed and takes the repository
    /// directly (see the ⛔ on ``SchedulingEventTypeEditorModel``); the read model
    /// keeps its own copy private, which is the right default for a type whose job
    /// is the read.
    private let admin: SchedulingAdminRepository

    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        self.workspaceId = workspaceId
        self.role = role
        admin = container.schedulingAdmin
        _model = State(initialValue: SchedulingEventTypesModel(
            container: container,
            workspaceId: workspaceId
        ))
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        SchedulingSectionScroll(
            title: SchedulingCopy.sectionTitle(.eventTypes),
            identifier: A11yID.Scheduling.eventTypesRoot,
            onRefresh: { await model.load() },
            content: {
                content
            }
        )
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            LoadingView(message: SchedulingCopy.loadingEventTypes)
        case let .failed(failure):
            FailureView(failure: failure, onRetry: reload)
        case .ready:
            create
            rows
        }
    }

    /// ⛔ DRAWN ONLY ON `.ready`, AND NOT BECAUSE A BUTTON NEEDS A LIST TO SIT UNDER.
    /// The editor refuses a slug the tenancy already holds, and the set it checks
    /// against is the rows this screen loaded; offering a create over a FAILED read
    /// would check the new slug against an empty set and let the server refuse it
    /// instead, after the operator had filled the form in.
    ///
    /// ⚠️ GATED THE SAME WAY THE WEB GATES IT. `eventTypes.create` is `client`-level,
    /// so the control is absent rather than disabled for a viewer — a greyed button
    /// tells somebody a thing exists and that they are shut out of it, which on a
    /// screen they can otherwise use fully is noise.
    @ViewBuilder
    private var create: some View {
        if WorkspaceRole.allowsMutation(role) {
            SchedulingEventTypeCreateButton(
                admin: admin,
                workspaceId: workspaceId,
                takenSlugs: model.rows.map(\.slug),
                onSaved: reload
            )
        }
    }

    @ViewBuilder
    private var rows: some View {
        let rows = model.rows
        if rows.isEmpty {
            SchedulingEmptyState(
                title: SchedulingCopy.eventTypesEmptyTitle,
                message: SchedulingCopy.eventTypesEmptyBody
            )
        } else {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    link(row)
                    if row.id != rows.last?.id {
                        DistrictRowDivider()
                    }
                }
            }
            .background(colors.card, in: RoundedRectangle(cornerRadius: DistrictRadius.card))
            .overlay {
                RoundedRectangle(cornerRadius: DistrictRadius.card)
                    .strokeBorder(colors.border, lineWidth: 1)
            }
        }
    }

    /// ⚠️ THE ROW OPENS THE INSPECTOR, WHICH IS A READ. The web's name cell links to an
    /// EDITOR; this one leads to ``SchedulingEventTypeView``, and its own header says so
    /// rather than letting the tap imply an edit that is not there.
    private func link(_ row: SchedulingEventTypesModel.Row) -> some View {
        NavigationLink(value: Route.scheduling(
            workspaceId: workspaceId,
            role: role,
            section: .eventType(slug: row.slug)
        )) {
            DistrictListRow(
                title: row.name,
                subtitle: SchedulingCopy.eventTypeSubtitle(duration: row.duration, location: row.location),
                trailing: { DistrictBadge(text: row.state.label, tone: row.state.kind.tone) }
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(A11yID.Scheduling.eventTypeRow(row.slug))
    }

    private func reload() {
        Task { await model.load() }
    }
}
