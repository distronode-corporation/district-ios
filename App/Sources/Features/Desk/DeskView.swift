import DistrictModel
import SwiftUI

/// District Desk — the tenant's OWN customers' queue.
///
/// ⛔ NOT THE SUPPORT DESK. Every string comes from ``DeskCopy``, which exists to keep
/// the two apart: this screen is the tenant's customers writing to the TENANT, and
/// Support is the tenant writing to DISTRONODE. A shortened title on either surface
/// undoes the distinction in one word.
///
/// ⛔ FOUR SCREENS, NOT TWO, AND THE FOURTH IS THE ONE THIS REPO KEEPS LOSING. On,
/// off, could-not-ask and empty are four different facts. An empty queue drawn for a
/// desk that is OFF says "no customer has ever contacted you"; drawn for a settings
/// read that FAILED it says the same thing with even less basis. ``DeskAvailability``
/// is what keeps them apart and this view renders all four.
///
/// ⚠️ NO `NavigationStack` OF ITS OWN. ``ShellView`` provides one per tab and registers
/// `navigationDestination(for: Route.self)` on it exactly once; SwiftUI resolves that
/// by TYPE, so a second registration here would be a runtime coin toss rather than a
/// compile error.
///
/// ⚠️ A `List` DRAWN TO LOOK LIKE THE PADDED STACK IT WAS, so the open ticket can stay
/// selected beside its thread on regular width. Each block is a row spaced as the stack
/// spaced it, and the queue's card is one slice per ticket; `StackedListRows.swift`
/// says what each modifier undoes.
struct DeskView: View {
    @State private var model: DeskModel
    @State private var composing = false
    @State private var settingsOpen = false

    private let container: AppContainer
    private let role: WorkspaceRole?

    /// The open ticket, on regular width only; nil on the phone. See ``RouteList``.
    private let selection: Binding<Route?>?

    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?, selection: Binding<Route?>? = nil) {
        self.container = container
        self.role = role
        self.selection = selection
        _model = State(initialValue: DeskModel(
            container: container,
            workspaceId: workspaceId,
            role: role
        ))
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        RouteList(selection: selection) {
            Text(DeskCopy.subtitle)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .stackedListRow(top: DistrictSpacing.gutter)
            if model.notice != nil {
                notice
                    .stackedListRow(top: DistrictSpacing.section)
            }
            content
        }
        .stackedList()
        .navigationTitle(DeskCopy.title)
        .toolbar { toolbar }
        .task { await model.load() }
        .districtRefreshable { await model.load() }
        .sheet(isPresented: $composing) {
            DeskComposeSheet(model: model)
        }
        .sheet(isPresented: $settingsOpen) {
            // ⚠️ RELOADS ON DISMISS, because the settings sheet is the only place the
            // desk can be switched on and this screen's whole shape depends on that
            // answer. Without it an operator turns the desk on and comes back to the
            // "District Desk is off" card they just acted on.
            DeskSettingsView(
                container: container,
                workspaceId: model.workspaceId,
                role: role,
                onDismiss: { Task { await model.load() } }
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(DeskCopy.offAction) { settingsOpen = true }
                .disabled(!model.canWrite)
        }
    }

    @ViewBuilder
    private var notice: some View {
        if let text = model.notice {
            Button(action: model.dismissNotice) {
                Text(text)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DistrictSpacing.gutter)
                    .background(colors.muted, in: RoundedRectangle(cornerRadius: DistrictRadius.card))
            }
            .buttonStyle(.plain)
        }
    }

    /// ⛔ THE FOUR STATES, IN THE ORDER THAT MAKES THEM DISTINGUISHABLE. `off` and
    /// `unknown` both short-circuit the queue entirely, because whatever the queue
    /// says cannot be interpreted without knowing which of the two we are in.
    @ViewBuilder
    private var content: some View {
        switch model.availability {
        case .checking:
            LoadingView(message: DeskCopy.loadingQueue)
                .stackedListRow(top: DistrictSpacing.section, bottom: DistrictSpacing.gutter)
        case .off:
            offCard
                .stackedListRow(top: DistrictSpacing.section, bottom: DistrictSpacing.gutter)
        case let .unknown(failure):
            unknownCard(failure)
                .stackedListRow(top: DistrictSpacing.section, bottom: DistrictSpacing.gutter)
        case .on:
            queue
        }
    }

    /// ⛔ SAYS WHICH FACT THIS IS AND WHERE THE SWITCH LIVES. An empty list here would
    /// be a lie: nothing is being recorded, which is not the same as nobody having
    /// written in.
    private var offCard: some View {
        EmptyStateView(
            systemImage: "tray",
            title: DeskCopy.offTitle,
            message: DeskCopy.offMessage
        ) {
            if model.canWrite {
                Button(DeskCopy.offAction) { settingsOpen = true }
                    .buttonStyle(DistrictButtonStyle(variant: .secondary))
            }
        }
    }

    /// ⛔ THE READ FAILED, AND SAYING SO IS THE WHOLE POINT OF THIS ARM. It is neither
    /// "your desk is off" nor "you have no tickets", and rendering it as either would be
    /// a failure drawn as an absence.
    private func unknownCard(_ failure: FailureText) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            Text(DeskCopy.unknownTitle)
                .font(DistrictType.title)
                .foregroundStyle(colors.foreground)
            Text(DeskCopy.unknownMessage)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            FailureView(failure: failure, onRetry: { Task { await model.load() } })
        }
        .padding(DistrictSpacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .districtCardSurface()
    }

    @ViewBuilder
    private var queue: some View {
        switch model.queue {
        case .loading:
            LoadingView(message: DeskCopy.loadingQueue)
                .stackedListRow(top: DistrictSpacing.section, bottom: DistrictSpacing.gutter)
        case let .failed(failure):
            FailureView(failure: failure, onRetry: { Task { await model.reloadQueue() } })
                .stackedListRow(top: DistrictSpacing.section, bottom: DistrictSpacing.gutter)
        case .ready:
            filters
                .stackedListRow(top: DistrictSpacing.section)
            rows
        }
    }

    /// ⚠️ THE CHIPS COUNT THE WHOLE QUEUE, WHICH IS WHY THE READ IS UNFILTERED. A
    /// server-side filter would mean one request per chip and the counts could
    /// disagree with each other between responses.
    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DistrictSpacing.tight) {
                chip(nil, DeskCopy.allFilter)
                ForEach(DeskTicketStatus.allCases, id: \.rawValue) { status in
                    chip(status, Self.label(for: status))
                }
            }
        }
    }

    private func chip(_ status: DeskTicketStatus?, _ label: String) -> some View {
        let active = model.filter == status
        let count = model.count(of: status)
        return Button { model.select(status) } label: {
            // ⚠️ SPELLED OUT FOR ACCESSIBILITY. SwiftUI concatenates the label and the
            // count into one token, so the computed name reads "All3" without this.
            Text("\(label) \(count)")
                .font(DistrictType.label)
                .foregroundStyle(active ? colors.district : colors.mutedForeground)
                .padding(.horizontal, DistrictSpacing.row)
                .frame(minHeight: 44)
                .background(
                    active ? colors.district.opacity(DistrictColors.containerAlpha) : colors.muted,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label), \(count)")
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    @ViewBuilder
    private var rows: some View {
        if model.allTickets.isEmpty {
            EmptyStateView(
                systemImage: "tray",
                title: DeskCopy.emptyTitle,
                message: DeskCopy.emptyMessage
            )
            .stackedListRow(top: DistrictSpacing.section, bottom: DistrictSpacing.gutter)
        } else if model.visibleTickets.isEmpty {
            // ⚠️ REACHABLE ONLY WITH A STATUS CHIP SELECTED: with All chosen the
            // visible rows are the whole queue and the branch above has it.
            EmptyStateView(
                systemImage: "line.3.horizontal.decrease",
                title: DeskCopy.noMatchTitle,
                message: DeskCopy.noMatchMessage
            )
            .stackedListRow(top: DistrictSpacing.section, bottom: DistrictSpacing.gutter)
        } else {
            ForEach(model.visibleTickets, id: \.id) { ticket in
                ticketRow(ticket, in: model.visibleTickets)
            }
        }
    }

    /// One ticket, as its slice of the queue's card.
    ///
    /// ⛔ THE LINK IS THE ROW, WITH THE DIVIDER INSIDE IT. A `List` turns a row's link into
    /// a selection when the link IS the row, which is the documented shape; a link nested
    /// in a stack beside a divider is not, and on regular width a link that pushed instead
    /// would be pushing from a column that has no stack.
    private func ticketRow(_ ticket: DeskTicketSummary, in tickets: [DeskTicketSummary]) -> some View {
        let first = ticket.id == tickets.first?.id
        let last = ticket.id == tickets.last?.id
        let route = destination(ticket)
        return NavigationLink(value: route) {
            VStack(spacing: 0) {
                DeskTicketRow(ticket: ticket)
                if !last {
                    DistrictRowDivider()
                }
            }
            .modifier(CardSlice(first: first, last: last, selected: selection?.wrappedValue == route))
        }
        .plainRouteRow()
        .stackedListRow(top: first ? DistrictSpacing.section : 0, bottom: last ? DistrictSpacing.gutter : 0)
    }

    private func destination(_ ticket: DeskTicketSummary) -> Route {
        .deskTicket(workspaceId: model.workspaceId, role: role, ticketId: ticket.id)
    }

    /// ⛔ `waiting` IS WORDED FROM THE CUSTOMER'S SIDE, which is what the column means:
    /// the team has answered and the ball is with them. "Waiting" alone reads as the
    /// team waiting, which inverts the one thing the badge is for.
    static func label(for status: DeskTicketStatus) -> String {
        switch status {
        case .open: "Open"
        case .waiting: "Waiting on customer"
        case .resolved: "Resolved"
        }
    }

    /// ⚠️ AN UNKNOWN STATUS IS DISPLAYED AS ITSELF. The column is free text
    /// server-side, so a state this build predates must reach the screen as a value
    /// rather than as a guess — painting it "Resolved" would tell an operator a
    /// customer has been dealt with.
    static func label(forWire status: String) -> String {
        guard let known = DeskTicketStatus(rawValue: status) else { return status }
        return label(for: known)
    }

    /// ⚠️ NEUTRAL FOR ANYTHING UNMODELLED, for the same reason ``Tone/forCallStatus(_:)``
    /// is: a tone asserts something about a state, and this client does not understand
    /// one it has not learned.
    static func tone(forWire status: String) -> Tone {
        switch DeskTicketStatus(rawValue: status) {
        case .open: .warning
        case .waiting: .info
        case .resolved: .success
        case nil: .neutral
        }
    }
}

/// One row of the queue.
///
/// ⛔ THE REFERENCE IS THE SERVER'S `displayReference`, NEVER REBUILT FROM `reference`.
/// It is spoken aloud by the voice agent and printed in the customer's email, so a
/// second formatter here is how the phone and the phone call start disagreeing about
/// the same ticket.
struct DeskTicketRow: View {
    let ticket: DeskTicketSummary

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        HStack(alignment: .top, spacing: DistrictSpacing.row) {
            VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                Text(ticket.displayReference)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
                Text(ticket.subject)
                    .font(DistrictType.titleSmall)
                    .foregroundStyle(colors.foreground)
                    .lineLimit(2)
                Text(DeskTicketRow.requesterLine(ticket))
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
                    .lineLimit(1)
            }
            Spacer(minLength: DistrictSpacing.tight)
            VStack(alignment: .trailing, spacing: DistrictSpacing.hairline) {
                DeskStatusBadge(status: ticket.status)
                if ticket.fromCall {
                    Text(DeskCopy.fromCall)
                        .font(DistrictType.caption)
                        .foregroundStyle(colors.mutedForeground)
                }
            }
        }
        .padding(DistrictSpacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// ⚠️ WHICHEVER IDENTIFIERS THE WORKSPACE ACTUALLY HOLDS. A ticket raised from a
    /// call may have only a number; one raised by hand may have only a name.
    static func requesterLine(_ ticket: DeskTicketSummary) -> String {
        let parts = [ticket.requesterName, ticket.requesterEmail, ticket.requesterPhone]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? DeskCopy.noContactDetails : parts.joined(separator: " · ")
    }
}

/// The status badge, tone included.
struct DeskStatusBadge: View {
    let status: String

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        let tone = DeskView.tone(forWire: status)
        let increased = colorSchemeContrast == .increased
        return Text(DeskView.label(forWire: status))
            .font(DistrictType.label)
            .foregroundStyle(tone.ink(colors, increasedContrast: increased))
            .padding(.horizontal, DistrictSpacing.tight)
            .padding(.vertical, DistrictSpacing.hairline)
            .background(
                tone.fill(colors, increasedContrast: increased),
                in: RoundedRectangle(cornerRadius: DistrictRadius.badge)
            )
    }
}
