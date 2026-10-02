import DistrictData
import DistrictModel
import Observation
import SwiftUI

/// Every booking in the workspace, upcoming and past.
///
/// ⛔ THE ONLY PAGED SCREEN ON THIS SURFACE, AND IT PAGES BY OFFSET OVER LIVE DATA. Event
/// types, recordings, teams, keys, apps and webhooks all arrive whole; this one does not,
/// and the consequences are the ones ``OffsetPager`` was written for — the same row can
/// arrive on two pages when a booking is created between requests, and the offset must
/// advance by the RAW page size rather than the deduplicated one or the list never ends.
///
/// ⚠️ IT USES ``OffsetPager`` RATHER THAN REIMPLEMENTING THAT. The pager takes a fetch
/// closure and owns the dedupe set, the offset and the end flag; the three rules it
/// encodes were derived once against the real server and are exactly the ones that get
/// subtly wrong when a second list reimplements them.
@MainActor
@Observable
final class SchedulingBookingsModel {
    private(set) var rows: [Row] = []
    private(set) var state: SchedulingSectionState<Void> = .loading
    private(set) var loadingMore = false
    private(set) var isEnd = false
    private(set) var timezone = "UTC"

    /// ⚠️ THE FILTER THE OPERATOR CHOSE. Changing it resets the pager, because an offset
    /// is meaningless against a different query.
    private(set) var view: SchedulingBookingView = .upcoming

    /// ⛔ FROM THE STATUS READ, AND IT DECIDES WHETHER `scope: "all"` IS SENT. The server
    /// ignores it for a non-admin, so a screen that captioned the result as the whole
    /// tenancy's on the strength of having asked would be wrong for most people.
    private(set) var canManage = false

    /// ⛔ THE SCHEDULER'S OWN ADMIN FLAG, WHICH IS NOT THE DISTRICT ROLE AND IS THE
    /// ONLY THING THAT MAY GATE A REASSIGN. The web offers "Change host" exactly
    /// where `me.get` answers `is_admin`; deriving it from ``WorkspaceRole`` would
    /// offer the control to a District client whom the fork then refuses, and hide
    /// it from a scheduler administrator the fork would have admitted.
    ///
    /// ⚠️ FALSE WHEN THE PROFILE READ FAILED, which is the safe direction: the row
    /// keeps its other two actions and nobody is shown a button that 403s.
    private(set) var schedulerIsAdmin = false

    /// ⚠️ CACHED FOR THE WHOLE SCREEN. Every row resolves its event type's display name
    /// through this, and re-reading the list per page would be a request per scroll.
    private var eventTypes: [SchedulingEventType] = []

    private let repository: SchedulingAdminRepository
    private let scheduling: SchedulingRepository
    private let workspaceId: String
    private var pager: OffsetPager<SchedulingBooking>?

    /// ⚠️ TWENTY-FIVE, WELL UNDER THE CATALOG'S 200 CEILING. A booking row is three lines
    /// on a phone, so a larger page buys latency for rows nobody scrolls to.
    static let pageSize = 25

    struct Row: Identifiable {
        let id: String
        let when: String
        let who: String
        let email: String
        let eventType: String
        let host: String
        let status: SchedulingStatusLabel

        /// ⛔ THE ROW THE SERVER SENT, CARRIED WHOLE, BECAUSE THE THREE WRITES NEED
        /// FIELDS THE FORMATTED COLUMNS HAVE ALREADY THROWN AWAY: `event_type_slug`
        /// addresses the slots read, `host_id` is left out of the reassign
        /// candidates, and `end_at` plus `status` are what
        /// ``SchedulingBookingFormat/isActionable(_:now:)`` judges. Re-deriving any
        /// of them from a rendered string would be this client parsing its own
        /// output.
        let booking: SchedulingBooking
    }

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
        rows = []
        isEnd = false
        await loadContext()
        makePager()
        await loadMore()
    }

    /// ⚠️ THE PROFILE, THE SCOPE AND THE EVENT TYPES, ALL BEFORE THE FIRST PAGE. Each one
    /// changes how a row RENDERS or what the query asks for, so fetching them alongside
    /// page one would draw a first page with the wrong zone and unresolved slugs, then
    /// rewrite it under the reader. The three do not depend on each other, so they are
    /// sent together.
    private func loadContext() async {
        async let statusRead = scheduling.status(workspaceId: workspaceId)
        async let profile = try? repository.me(workspaceId: workspaceId)
        async let types = try? repository.listEventTypes(workspaceId: workspaceId)
        if case let .success(status) = await statusRead {
            canManage = status.canManage
        }
        if let me = await profile {
            timezone = me.displayTimezone
            schedulerIsAdmin = me.isAdmin
        }
        eventTypes = await types ?? []
    }

    /// ⛔ A FRESH PAGER PER QUERY. ``OffsetPager``'s dedupe set is per instance and that is
    /// load-bearing: reusing one across a filter change would filter out the very rows the
    /// new query just fetched and present an empty list.
    private func makePager() {
        let params = SchedulingBookingFormat.listParams(
            for: SchedulingBookingQuery(
                view: view,
                limit: Self.pageSize,
                workspaceWide: canManage
            )
        )
        let repository = repository
        let workspaceId = workspaceId
        pager = OffsetPager<SchedulingBooking>(
            identify: { $0.id },
            fetch: { limit, offset in
                do {
                    let page = try await repository.bookings(
                        workspaceId: workspaceId,
                        status: params.status,
                        when: params.when,
                        from: params.from,
                        to: params.to,
                        eventTypeSlug: params.eventTypeSlug,
                        host: params.host,
                        team: params.team,
                        limit: limit,
                        offset: offset,
                        allHosts: params.allHosts,
                        order: params.order
                    )
                    return .success(OffsetPage(items: page.items, total: page.total))
                } catch {
                    // ⚠️ THE PAGER SPEAKS `ApiError` AND THIS SURFACE THROWS
                    // `SchedulingAdminError`, so the two vocabularies meet here. The
                    // status is carried across rather than the sentence, and
                    // `SchedulingFailureCopy` maps it back on the way out — which keeps
                    // the five-code wording identical to every other scheduling screen.
                    return .failure(Self.apiError(for: error))
                }
            }
        )
    }

    /// ⛔ THE MAPPING IS DELIBERATELY LOSSY IN ONE DIRECTION ONLY. `SchedulingAdminError`
    /// has no HTTP status to hand back (see the ⚠️ on that type — the escape hatch was
    /// removed on purpose), so each code is given the status that maps BACK to it through
    /// `FailureText`, and the screen re-derives its sentence from the original error
    /// rather than from this. Nothing user-facing reads the value.
    /// ⚠️ `nonisolated` BECAUSE IT IS CALLED FROM INSIDE THE PAGER'S `@Sendable` FETCH
    /// CLOSURE, which runs off the main actor. It touches no state and needs none, so the
    /// annotation costs nothing; without it the closure cannot reach a static member of a
    /// `@MainActor` type.
    private nonisolated static func apiError(for error: any Error) -> ApiError {
        guard let admin = error as? SchedulingAdminError else {
            return .http(status: 500, message: nil)
        }
        switch admin.uiCode {
        case .unavailable: return .http(status: 503, message: nil)
        case .forbidden: return .http(status: 403, message: nil)
        case .notReady: return .http(status: 409, message: nil)
        case .slotTaken, .unknown: return .http(status: 400, message: nil)
        }
    }

    func selectView(_ next: SchedulingBookingView) async {
        guard next != view else { return }
        view = next
        state = .loading
        rows = []
        isEnd = false
        makePager()
        await loadMore()
    }

    /// ⛔ AN EMPTY SLICE DOES NOT END THE LIST. ``OffsetSlice`` can legitimately be empty
    /// while `isEnd` is false — every row in that window had already been seen — and a
    /// caller that stopped on it would truncate the feed. Only `isEnd` ends it.
    func loadMore() async {
        guard let pager, !loadingMore, !isEnd else { return }
        loadingMore = true
        defer { loadingMore = false }
        switch await pager.loadNext(limit: Self.pageSize) {
        case let .success(slice):
            rows.append(contentsOf: slice.items.map(makeRow))
            isEnd = slice.isEnd
            state = .ready(())
        case let .failure(error):
            // ⚠️ A FAILED FIRST PAGE IS A SCREEN FAILURE AND A FAILED LATER PAGE IS NOT.
            // Blanking a list somebody has scrolled through because page four timed out
            // would discard rows that are still correct.
            if rows.isEmpty {
                state = .failed(FailureText.from(error))
            }
        }
    }

    private func makeRow(_ booking: SchedulingBooking) -> Row {
        Row(
            id: booking.id,
            when: SchedulingBookingFormat.bookingDateTime(
                startAt: booking.startAt,
                timezone: timezone
            ) ?? SchedulingCopy.unknownTime,
            who: SchedulingOverviewSummary.bookingWho(booking),
            email: SchedulingBookingFormat.attendeeEmail(booking),
            eventType: SchedulingOverviewSummary.bookingEventTypeName(
                booking,
                eventTypes: eventTypes
            ),
            // ⚠️ AN EM DASH FOR AN UNASSIGNED HOST, matching the web's Host column.
            host: booking.hostName ?? "—",
            status: SchedulingBookingFormat.statusLabel(booking.status),
            booking: booking
        )
    }

    // MARK: - Writes

    // ⛔ THREE WRITES BELONG HERE AND EACH NEEDS A DIFFERENT GATE. `bookings.cancel` and
    // `bookings.reschedule` are `client`-level AND must additionally be gated on
    // ``SchedulingBookingFormat/isActionable(_:now:)``, which is judged on `end_at` — a
    // meeting that started ten minutes ago is still cancellable and one that ended ten
    // minutes ago is not. `bookings.reassign` is narrower still: the web offers it only
    // when the SCHEDULER reports `is_admin`, which is a different bar from the District
    // role and has to be read from `me.get`.
    //
    // ⚠️ `isActionable` IS ALREADY PORTED AND ALREADY TESTED, unused, for exactly this.
}

struct SchedulingBookingsView: View {
    @State private var model: SchedulingBookingsModel

    private let workspaceId: String
    private let role: WorkspaceRole?
    private let admin: SchedulingAdminRepository

    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        self.workspaceId = workspaceId
        self.role = role
        admin = container.schedulingAdmin
        _model = State(initialValue: SchedulingBookingsModel(
            container: container,
            workspaceId: workspaceId
        ))
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        SchedulingSectionScroll(
            title: SchedulingCopy.sectionTitle(.bookings),
            identifier: A11yID.Scheduling.bookingsRoot,
            onRefresh: { await model.load() },
            content: {
                header
                content
            }
        )
        .task { await model.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            Text(SchedulingCopy.timesIn(model.timezone))
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            views
        }
    }

    /// ⚠️ BUTTONS RATHER THAN A `Picker`, matching ``MarketplaceView``: this design system
    /// has no tab component, and inventing one for a single screen is how a second,
    /// drifting set of primitives starts.
    private var views: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DistrictSpacing.tight) {
                ForEach(SchedulingBookingView.allCases, id: \.self) { option in
                    Button(option.label) {
                        Task { await model.selectView(option) }
                    }
                    .buttonStyle(DistrictButtonStyle(
                        variant: model.view == option ? .primary : .secondary
                    ))
                }
            }
        }
        .accessibilityIdentifier(A11yID.Scheduling.bookingsView)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            LoadingView(message: SchedulingCopy.loadingBookings)
        case let .failed(failure):
            FailureView(failure: failure, onRetry: reload)
        case .ready:
            rows
        }
    }

    @ViewBuilder
    private var rows: some View {
        if model.rows.isEmpty {
            SchedulingEmptyState(
                title: SchedulingCopy.bookingsEmptyTitle,
                message: SchedulingCopy.bookingsEmptyBody(model.view)
            )
        } else {
            VStack(spacing: 0) {
                ForEach(model.rows) { row in
                    link(row)
                    actions(row)
                    if row.id != model.rows.last?.id {
                        DistrictRowDivider()
                    }
                }
            }
            .districtCardSurface()
            more
        }
    }

    /// ⛔ AN EXPLICIT BUTTON RATHER THAN AN `onAppear` ON THE LAST ROW. Infinite scroll
    /// inside a `ScrollView` fires its trigger during layout, which on a list that grows
    /// under it can spend several pages before the first one has been read; a button
    /// spends exactly one request per tap and makes the end of the list legible.
    @ViewBuilder
    private var more: some View {
        if !model.isEnd {
            Button(model.loadingMore ? SchedulingCopy.loadingMore : SchedulingCopy.loadMore) {
                Task { await model.loadMore() }
            }
            .buttonStyle(.districtSecondary)
            .disabled(model.loadingMore)
        }
    }

    private func link(_ row: SchedulingBookingsModel.Row) -> some View {
        NavigationLink(value: Route.scheduling(
            workspaceId: workspaceId,
            role: role,
            section: .booking(id: row.id)
        )) {
            DistrictListRow(
                title: row.when,
                subtitle: SchedulingCopy.bookingSubtitle(
                    who: row.who,
                    eventType: row.eventType,
                    host: row.host
                ),
                trailing: { DistrictBadge(text: row.status.label, tone: row.status.kind.tone) }
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(A11yID.Scheduling.bookingRow(row.id))
    }

    /// ⛔ UNDER THE ROW RATHER THAN INSIDE IT. The row is a `NavigationLink`, and a
    /// button nested in a link's label competes with the link for the tap — on a
    /// list where one of the buttons cancels a customer's meeting, that is not a
    /// gesture to leave ambiguous.
    ///
    /// ⛔ TWO GATES, BOTH REQUIRED. `client` for the three ops, and `isActionable`
    /// for the booking: it is judged on `end_at`, so a meeting that has started is
    /// still cancellable and one that has finished is not. A cancelled booking
    /// fails the same test on its status.
    @ViewBuilder
    private func actions(_ row: SchedulingBookingsModel.Row) -> some View {
        if WorkspaceRole.allowsMutation(role), SchedulingBookingFormat.isActionable(row.booking) {
            SchedulingBookingWriteBar(
                admin: admin,
                workspaceId: workspaceId,
                booking: row.booking,
                timezone: model.timezone,
                mayReassign: model.schedulerIsAdmin,
                onChanged: reload
            )
            .padding(.horizontal, DistrictSpacing.row)
            .padding(.bottom, DistrictSpacing.tight)
        }
    }

    private func reload() {
        Task { await model.load() }
    }
}
