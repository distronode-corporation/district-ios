import DistrictModel
import SwiftUI

/// One ticket: the thread, the status control and the reply box.
///
/// ⛔ THE COMPOSER APPENDS ONLY WHAT THE SERVER SAYS IT WROTE. There is no optimistic
/// echo here and there must never be one: showing the draft would tell an operator
/// their customer had been answered when the message may never have been stored, which
/// is the worst thing this screen can do, because the customer is waiting. The two
/// outcomes are handled in ``DeskTicketModel``; this view only draws them.
///
/// ⛔ THE AUTHOR LABEL IS DERIVED HERE BECAUSE THE SERVER SENDS NONE, and all three
/// kinds are supplied rather than left to a fallback: the shared conventions on this
/// programme name Distronode, which is the wrong company on a tenant's own desk.
struct DeskTicketView: View {
    @State private var model: DeskTicketModel

    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String, ticketId: String, role: WorkspaceRole?) {
        _model = State(initialValue: DeskTicketModel(
            container: container,
            workspaceId: workspaceId,
            ticketId: ticketId,
            role: role
        ))
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                content
            }
            .padding(DistrictSpacing.gutter)
            .districtReadableWidth()
        }
        .navigationTitle(model.ticket?.displayReference ?? DeskCopy.threadFallbackTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.thread {
        case .loading:
            LoadingView(message: DeskCopy.loadingThread)
        case let .failed(failure):
            FailureView(failure: failure, onRetry: { Task { await model.load() } })
        case let .ready(ticket):
            header(ticket)
            statusControl(ticket)
            notice
            messages(ticket)
            if model.canWrite {
                composer
            }
        }
    }

    private func header(_ ticket: DeskTicketDetail) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            DistrictEyebrow(text: ticket.displayReference)
            Text(ticket.subject)
                .font(DistrictType.titleLarge)
                .foregroundStyle(colors.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Text(DeskTicketView.requesterLine(ticket))
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            if ticket.fromCall {
                Text(DeskCopy.fromCall)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// ⛔ EVERY BUTTON IS DISABLED WHILE A WRITE IS IN FLIGHT, and the current status
    /// is disabled too: re-posting the state a ticket already has is a write that
    /// changes nothing and can still clear `resolvedAt` on the way past.
    private func statusControl(_ ticket: DeskTicketDetail) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            DistrictEyebrow(text: DeskCopy.setStatus)
            HStack(spacing: DistrictSpacing.tight) {
                ForEach(DeskTicketStatus.allCases, id: \.rawValue) { status in
                    Button(DeskView.label(for: status)) {
                        Task { await model.setStatus(status) }
                    }
                    .buttonStyle(DistrictButtonStyle(
                        variant: ticket.status == status.rawValue ? .primary : .secondary,
                        size: .small
                    ))
                    .disabled(!model.canWrite || model.busy || ticket.status == status.rawValue)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    @ViewBuilder
    private func messages(_ ticket: DeskTicketDetail) -> some View {
        if ticket.messages.isEmpty {
            Text(DeskCopy.emptyThread)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
        } else {
            VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                ForEach(ticket.messages, id: \.id) { message in
                    DeskMessageCard(message: message, ticket: ticket)
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            SettingsField(
                label: DeskCopy.replyPlaceholder,
                // ⛔ A CLOSURE LITERAL, NEVER `set: model.editDraft`. A bare
                // MainActor-isolated method reference as a `Binding` setter aborts the
                // compiler in IRGen under Swift 6 with no `error:` line.
                text: Binding(get: { model.draft }, set: { model.editDraft($0) }),
                enabled: !model.busy,
                multiline: true
            )
            HStack {
                Spacer()
                Button(DeskCopy.sendReply) { Task { await model.sendReply() } }
                    .buttonStyle(DistrictButtonStyle(size: .small))
                    .disabled(!model.canSend)
            }
        }
    }

    /// ⚠️ WHICHEVER IDENTIFIERS THE WORKSPACE HOLDS, and a plain sentence when it holds
    /// none. Blank space where contact details belong reads as a broken row.
    static func requesterLine(_ ticket: DeskTicketDetail) -> String {
        let parts = [ticket.requesterName, ticket.requesterEmail, ticket.requesterPhone]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? DeskCopy.noContactDetails : parts.joined(separator: " · ")
    }
}

/// One message in the thread.
///
/// ⛔ THREE AUTHOR KINDS, TWO SIDES. The customer is one side; the team and the agent
/// are the other, and a renderer that collapsed them would tell an operator their own
/// agent's call summary was written by the person who rang. The SIDE decides the
/// alignment and the tint; the LABEL says who.
///
/// ⚠️ AN UNKNOWN `authorType` SITS ON THE TEAM'S SIDE AND SAYS SO. Attributing it to
/// the customer is the damaging direction: it would put words in their mouth.
struct DeskMessageCard: View {
    let message: DeskMessage
    let ticket: DeskTicketDetail

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(author)
                .font(DistrictType.label)
                .foregroundStyle(colors.mutedForeground)
            Text(message.body)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DistrictSpacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: DistrictRadius.card))
        .overlay {
            RoundedRectangle(cornerRadius: DistrictRadius.card)
                .strokeBorder(colors.border, lineWidth: 1)
        }
    }

    private var isCustomer: Bool {
        message.knownAuthor == .customer
    }

    private var fill: Color {
        isCustomer ? colors.muted : colors.card
    }

    private var author: String {
        switch message.knownAuthor {
        case .customer:
            let named = ticket.requesterName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (named?.isEmpty == false ? named : nil) ?? DeskCopy.authorCustomerFallback
        case .team:
            return DeskCopy.authorTeam
        case .assistant:
            return DeskCopy.authorAssistant
        case nil:
            return DeskCopy.authorUnknown
        }
    }
}
