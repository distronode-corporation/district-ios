import DistrictData
import DistrictModel
import Observation
import SwiftUI

/// The calendar accounts bookings are written to and checked against.
///
/// ⛔ THE OAuth LEG IS A HAND-OFF, NOT A NATIVE FLOW. Starting a connection means leaving
/// the app for a provider's consent screen and being handed back through a redirect this
/// client would have to claim; the web does it with a double-encoded `next` and a
/// `sessionStorage` round trip, none of which ports. So the connect control opens a
/// single-use hand-off in a browser sheet and the screen re-reads when it closes; see
/// the connect card on ``SchedulingCalendarView``.
@MainActor
@Observable
final class SchedulingCalendarModel {
    private(set) var state: SchedulingSectionState<SchedulingCalendarStatus> = .loading
    private(set) var zoom: SchedulingZoomStatus?

    /// ⛔ ONE ENTRY PER CONNECTION, AND A MISSING ONE IS **NOT** AN EMPTY ONE. The
    /// per-connection calendar read is allowed to fail on its own; nil then means "we could
    /// not read which calendars are selected" and the row falls back to the connection's
    /// own boolean, while an empty array means "we read them and none is selected". See
    /// the ⛔ on ``SchedulingCalendarFormat/conflictSummary(connection:calendars:)``.
    private(set) var calendars: [String: [SchedulingCalendarSelection]] = [:]

    private let repository: SchedulingAdminRepository
    private let workspaceId: String

    /// ⛔ THE DESIGNATED INITIALISER TAKES THE REPOSITORIES AND THE CONTAINER ONE
    /// DELEGATES TO IT, WHICH IS THE ONLY TEST SEAM ON THIS SURFACE. ``AppContainer``
    /// builds its own ``URLSessionHTTPTransport`` in `init`, so a test cannot hand it a
    /// fake; taking the collaborators directly lets `DistrictAITests` drive a real
    /// repository over a stub transport, which exercises the envelope walk rather than
    /// skipping it. ⚠️ Production still constructs through the container, so both
    /// collaborators remain the one shared ``ApiClient``.
    init(repository: SchedulingAdminRepository, workspaceId: String) {
        self.repository = repository
        self.workspaceId = workspaceId
    }

    convenience init(container: AppContainer, workspaceId: String) {
        self.init(repository: container.schedulingAdmin, workspaceId: workspaceId)
    }

    func load() async {
        state = .loading
        calendars = [:]
        do {
            let status = try await repository.calendarStatus(workspaceId: workspaceId)
            state = .ready(status)
            // ⚠️ THE ZOOM READ IS OPTIONAL AND ITS FAILURE IS SILENT. It reports whether a
            // separate integration is configured; a screen that failed over it would hide
            // the calendar connections, which are the point.
            zoom = try? await repository.zoomStatus(workspaceId: workspaceId)
            await loadCalendars(for: status.connections)
        } catch {
            state = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    /// ⚠️ ONE READ PER CONNECTION, CONCURRENTLY, EACH ALLOWED TO FAIL ALONE. Most tenancies
    /// have one or two; the loop is bounded by what the status read returned and nothing
    /// here retries.
    private func loadCalendars(for connections: [SchedulingCalendarConnection]) async {
        await withTaskGroup(of: (String, [SchedulingCalendarSelection]?).self) { group in
            for connection in connections {
                group.addTask { [repository, workspaceId] in
                    // ⚠️ THE PROVIDER AND THE ACCOUNT TRAVEL WITH THE ID, because the op
                    // takes all three: the connection id alone does not tell the fork
                    // which account's calendars to enumerate. Both come off the connection
                    // row the status read already answered, so nothing is derived here.
                    let rows = try? await repository.connectionCalendars(
                        workspaceId: workspaceId,
                        connectionId: connection.id,
                        provider: connection.provider,
                        accountEmail: connection.accountEmail
                    )
                    return (connection.id, rows)
                }
            }
            for await (id, rows) in group {
                // ⛔ ONLY A SUCCESSFUL READ IS RECORDED. Storing an empty array for a
                // failed one would turn "could not read" into "nothing selected", which is
                // the exact confusion `conflictSummary` exists to keep apart.
                if let rows {
                    calendars[id] = rows
                }
            }
        }
    }

    // MARK: - Writes

    // ⛔ FOUR WRITES, AND ALL FOUR ARE `viewer`-LEVEL, WHICH IS UNUSUAL ON THIS SURFACE.
    // `calendar.caldav.connect`, `calendar.connections.calendars.put`,
    // `calendar.connections.destination` and `calendar.connections.delete` touch only the
    // CALLER's own calendars, so the server admits a viewer deliberately: somebody who
    // cannot connect their own calendar cannot be booked at all. ⚠️ Do NOT gate these on
    // ``WorkspaceRole/allowsMutation(_:)`` — that would break the product
    // for exactly the role the narrow rule was meant to protect. See the ⛔ on
    // ``SchedulingAdminOp/minRole``.
    //
    // ⚠️ They also spend a SEPARATE 30-per-member-per-hour bucket rather than the
    // workspace's 120, which is why ``SchedulingAdminOp/isWrite`` disagrees with
    // `minRole == .client` on exactly these.
}

struct SchedulingCalendarView: View {
    @State private var model: SchedulingCalendarModel

    /// ⛔ OWNED BY THE SCREEN SO ONE PROMPT IS UP AT A TIME. The model holds the pending
    /// connection and each row's dialog presents only for it; see
    /// ``SchedulingWriteConfirmationsC``.
    @State private var disconnect: SchedulingCalendarDisconnectModel
    /// ⚠️ ONE PER SCREEN RATHER THAN ONE PER PROVIDER, because the hand-off URL it
    /// mints is single-use and lives about sixty seconds: the model answers one and
    /// stores none, so nothing is shared between two presses but the busy flag.
    @State private var connect: SchedulingCalendarConnectModel

    private let admin: SchedulingAdminRepository
    private let workspaceId: String

    @Environment(\.colorScheme) private var colorScheme

    /// ⛔ THE ROLE IS TAKEN AND DELIBERATELY UNUSED, AND THAT IS NOT AN OVERSIGHT.
    /// All four calendar writes are `viewer`-level in the op catalog because they
    /// touch only the CALLER's own calendars; gating them on
    /// ``WorkspaceRole/allowsMutation(_:)`` would stop a viewer connecting the
    /// calendar that makes them bookable at all. See the ⛔ on
    /// ``SchedulingCalendarWriteEntry``.
    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        _ = role
        self.workspaceId = workspaceId
        let admin = container.schedulingAdmin
        self.admin = admin
        let model = SchedulingCalendarModel(container: container, workspaceId: workspaceId)
        _model = State(initialValue: model)
        let refresh: () -> Void = { Task { await model.load() } }
        _disconnect = State(initialValue: SchedulingCalendarDisconnectModel(
            repository: admin,
            workspaceId: workspaceId,
            onChanged: refresh
        ))
        _connect = State(initialValue: SchedulingCalendarConnectModel(
            sso: container.schedulingSSO,
            baseURL: container.baseURL,
            workspaceId: workspaceId,
            onChanged: refresh
        ))
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        SchedulingSectionScroll(
            title: SchedulingCopy.sectionTitle(.calendar),
            identifier: A11yID.Scheduling.calendarRoot,
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
            LoadingView(message: SchedulingCopy.loadingCalendar)
        case let .failed(failure):
            FailureView(failure: failure, onRetry: reload)
        case let .ready(status):
            connections(status)
            connectCard(status)
        }
    }

    private func connections(_ status: SchedulingCalendarStatus) -> some View {
        ForEach(status.connections, id: \.id) { connection in
            SchedulingCard(eyebrow: SchedulingCalendarFormat.providerLabel(connection.provider)) {
                SchedulingReadOnlyRow(
                    label: SchedulingCopy.calendarAccount,
                    value: connection.accountEmail
                )
                SchedulingReadOnlyRow(
                    label: SchedulingCopy.calendarConflicts,
                    value: SchedulingCalendarFormat.conflictSummary(
                        connection: connection,
                        calendars: model.calendars[connection.id]
                    )
                )
                SchedulingReadOnlyRow(
                    label: SchedulingCopy.calendarDestination,
                    value: SchedulingCalendarFormat.destinationSummary(
                        connection: connection,
                        calendars: model.calendars[connection.id]
                    )
                )
                SchedulingCalendarRowActions(
                    admin: admin,
                    workspaceId: workspaceId,
                    connection: connection,
                    disconnectModel: disconnect,
                    onChanged: reload
                )
            }
        }
    }

    /// ⛔ THE WARNING IS DRAWN FROM THE ROW THAT WAS DELETED, NOT FROM THE RE-READ.
    /// A tenancy left with no destination writes new bookings nowhere, and after the
    /// status has been read again there is nothing left to ask — so the model records
    /// it before the refresh and this says so afterwards.
    @ViewBuilder
    private var disconnectMessages: some View {
        if let failure = disconnect.failure {
            SchedulingWriteFailureLineC(failure: failure, onDismiss: disconnect.dismissFailure)
        }
        if disconnect.removedDestination {
            SchedulingWriteNoticeLineC(message: SchedulingWriteCopyC.disconnectedLastDestination)
        }
    }

    /// ⛔ THE OAuth LEG LEAVES THE APP AND COMES BACK THROUGH A RE-READ, NOT THROUGH
    /// A CALLBACK. The provider's redirect lands on a page this process never sees,
    /// so ``SchedulingCalendarConnectSection`` re-reads when its browser sheet closes
    /// and the status is what says which accounts are connected. CalDAV is the other
    /// shape entirely: it is a form, it answers in-band, and it is offered whether or
    /// not the instance has OAuth providers configured.
    private func connectCard(_ status: SchedulingCalendarStatus) -> some View {
        SchedulingCard(eyebrow: SchedulingCopy.calendarConnectEyebrow) {
            Text(sentence(for: status))
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
            if let zoom = model.zoom, zoom.configured {
                SchedulingReadOnlyRow(
                    label: SchedulingCopy.calendarZoom,
                    value: zoom.connected ? SchedulingCopy.connected : SchedulingCopy.notConnected
                )
            }
            SchedulingCalendarConnectSection(model: connect, status: status)
            SchedulingCaldavConnectButton(
                admin: admin,
                workspaceId: workspaceId,
                onChanged: reload
            )
            disconnectMessages
        }
    }

    /// ⚠️ THREE SENTENCES, AND THE "not set up on this scheduler" ONE IS NOT A FAULT. A
    /// tenancy whose instance has no calendar providers configured cannot connect one at
    /// all, which is a different fact from having none connected yet.
    private func sentence(for status: SchedulingCalendarStatus) -> String {
        if !status.configured {
            return SchedulingCopy.calendarNotConfigured
        }
        return status.connections.isEmpty
            ? SchedulingCopy.calendarNoneConnected
            : SchedulingCopy.calendarConnectAnother
    }

    private func reload() {
        Task { await model.load() }
    }
}
