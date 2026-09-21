import DistrictModel
import SwiftUI

/// Support: the requests this workspace has raised with Distronode.
///
/// ⛔ THIS IS HELP **FROM DISTRONODE**, AND ITS MIRROR IMAGE IS THE DESK. The desk is
/// the tenant's own queue, their customers' tickets, answered by their agent. Both
/// have requests, threads and replies; the labels and the subtitle are the only thing
/// separating them, which is why the subtitle names Distronode and why a bare
/// "Tickets" here would undo the distinction the web sidebar's own comment demands.
///
/// ⛔ EVERY ROUTE BEHIND THIS SCREEN EXCLUDES `viewer`, THE READS INCLUDED. So there
/// is no read-only rendering of it: ``RouteGate`` answers `.hidden` and the row is
/// dropped from the Overview entirely. That is the opposite of Marketplace and
/// Billing, whose reads admit a viewer and which therefore carry a read-only caption.
///
/// ⚠️ NO `NavigationStack` OF ITS OWN. ``ShellView`` provides one per tab and
/// registers `navigationDestination(for: Route.self)` on it exactly once.
///
/// ⚠️ A `List` DRAWN TO LOOK LIKE THE PADDED STACK IT WAS, so the open request can stay
/// selected beside its thread on regular width. Each block is a row spaced as the stack
/// spaced it; `StackedListRows.swift` says what each modifier undoes.
struct SupportView: View {
    @State private var model: SupportModel

    private let workspaceId: String
    private let role: WorkspaceRole?

    /// The open request, on regular width only; nil on the phone. See ``RouteList``.
    private let selection: Binding<Route?>?

    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?, selection: Binding<Route?>? = nil) {
        _model = State(
            initialValue: SupportModel(container: container, workspaceId: workspaceId, role: role)
        )
        self.workspaceId = workspaceId
        self.role = role
        self.selection = selection
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        RouteList(selection: selection) {
            header
                .stackedListRow(top: DistrictSpacing.gutter)
            if model.create.notice != nil {
                SupportWriteNotice(state: model.create, onDismiss: { model.dismissNotice() })
                    .stackedListRow(top: DistrictSpacing.row)
            }
            Group {
                if model.composing {
                    composeCard
                } else {
                    actionBar
                }
            }
            .stackedListRow(top: DistrictSpacing.row)
            listSection
        }
        .stackedList()
        .navigationTitle(SupportCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }

    private var header: some View {
        Text(SupportCopy.subtitle)
            .font(DistrictType.bodySmall)
            .foregroundStyle(colors.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// ⚠️ THE RESPONSE-TIME LINE SITS BESIDE THE BUTTON AND IS NOT REPEATED IN THE
    /// EMPTY STATE, which is on screen at the same time. Saying it twice in one
    /// viewport reads as filler.
    private var actionBar: some View {
        HStack(alignment: .center, spacing: DistrictSpacing.tight) {
            Text(SupportCopy.sla)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.canWrite {
                Button(SupportCopy.newRequest) { model.beginCompose() }
                    .buttonStyle(.districtPrimary)
            }
        }
    }

    // MARK: - Composing

    private var composeCard: some View {
        SupportCard(eyebrow: SupportCopy.composeTitle) {
            kindPicker
            SettingsField(
                label: SupportCopy.composeSubject,
                text: subjectBinding,
                enabled: !model.create.isSending
            )
            SettingsField(
                label: SupportCopy.composeMessage,
                text: messageBinding,
                enabled: !model.create.isSending,
                multiline: true
            )
            Text(SupportCopy.composeMessageHint)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            if model.draftRejected {
                Text(SupportCopy.composeIncomplete)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.destructive)
            }
            composeControls
        }
    }

    /// ⚠️ BUTTONS RATHER THAN A `Picker`, for the reason ``KnowledgeView`` gives: a
    /// picker's binding fires on the gesture, and a row of buttons keeps the choice
    /// and its label in one place on a form this short.
    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(SupportCopy.composeKind)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            ForEach(SupportRequestKind.allCases, id: \.rawValue) { kind in
                Button(SupportCopy.kindLabel(kind)) { model.selectKind(kind) }
                    .buttonStyle(.districtSecondary)
                    .disabled(model.create.isSending || model.draftKind == kind)
            }
        }
    }

    private var composeControls: some View {
        HStack(spacing: DistrictSpacing.tight) {
            Button(SupportCopy.composeCancel) { model.cancelCompose() }
                .buttonStyle(.districtGhost)
                .disabled(model.create.isSending)
            Button(model.create.isSending ? SupportCopy.composeSending : SupportCopy.composeSend) {
                submit()
            }
            .buttonStyle(.districtPrimary)
            .disabled(!model.canSubmit)
        }
    }

    // MARK: - The list

    @ViewBuilder
    private var listSection: some View {
        switch model.list {
        case .loading:
            skeleton
                .stackedListRow(top: DistrictSpacing.row, bottom: DistrictSpacing.gutter)
        case let .ready(rows):
            rowsSection(rows)
        case let .failed(failure):
            listFailure(failure)
                .stackedListRow(top: DistrictSpacing.row, bottom: DistrictSpacing.gutter)
        }
    }

    private var skeleton: some View {
        VStack(spacing: DistrictSpacing.row) {
            ForEach(0 ..< 3, id: \.self) { _ in
                SkeletonBlock(height: 56)
            }
        }
    }

    /// ⛔ NOT THE EMPTY-QUEUE COPY. "No support requests yet" is a claim about the
    /// workspace; this is a statement about us. Rendering the former here would tell a
    /// customer with open tickets that they have none.
    private func listFailure(_ failure: FailureText) -> some View {
        SupportCard {
            Text(SupportCopy.listFailedTitle)
                .font(DistrictType.titleSmall)
                .foregroundStyle(colors.foreground)
            Text(SupportCopy.listFailedBody)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            FailureView(failure: failure, onRetry: reload)
        }
    }

    @ViewBuilder
    private func rowsSection(_ rows: [SupportRequestSummary]) -> some View {
        if rows.isEmpty {
            EmptyStateView(
                systemImage: "lifepreserver",
                title: SupportCopy.emptyTitle,
                message: SupportCopy.emptyBody
            )
            .stackedListRow(top: DistrictSpacing.row, bottom: DistrictSpacing.gutter)
        } else {
            ForEach(rows, id: \.id) { request in
                requestLink(request)
                    .stackedListRow(
                        top: DistrictSpacing.row,
                        bottom: request.id == rows.last?.id ? DistrictSpacing.gutter : 0
                    )
            }
        }
    }

    /// ⛔ THE LINK CARRIES `issueKey ?? id`, WHICH IS WHAT MAKES AN UNFILED REQUEST
    /// REACHABLE. The server's funnel accepts either spelling, and a request between
    /// its local claim and the Atlassian call has no key at all — keying the link on
    /// `issueKey` alone would make the one request a customer most wants to check on
    /// the one they cannot open.
    ///
    /// ⛔ THE LINK IS THE ROW, WITH THE DIVIDER INSIDE IT, because a `List` selects by the
    /// row's own link; see the same ⛔ on the Desk's ticket rows.
    private func requestLink(_ request: SupportRequestSummary) -> some View {
        let route = Route.supportRequest(workspaceId: workspaceId, role: role, key: request.issueKey ?? request.id)
        return NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: 0) {
                // ⛔ THE SLOT IS LABELLED. A TRAILING closure here is `ambiguous use of
                // 'init'`: the two single-slot initialisers on ``DistrictListRow`` are
                // equally good candidates and the compiler cannot tell which was meant.
                DistrictListRow(
                    title: request.subject,
                    subtitle: subtitle(for: request),
                    trailing: {
                        HStack(spacing: DistrictSpacing.hairline) {
                            SupportChips(source: request.source, region: request.region)
                            DistrictBadge(
                                text: request.statusName,
                                tone: SupportChrome.tone(for: request.statusCategory)
                            )
                        }
                    }
                )
                .background(selection?.wrappedValue == route ? selectedTint : Color.clear)
                DistrictRowDivider()
            }
        }
        .plainRouteRow()
    }

    /// ⚠️ THE ROW PAINTS ITS OWN SELECTION: its `List` row is clear so the page shows
    /// through, which leaves the system nothing to paint on. The tint is a selected
    /// filter chip's.
    private var selectedTint: Color {
        colors.district.opacity(DistrictColors.containerAlpha)
    }

    /// ⚠️ THE KEY IS SHOWN WHEN THERE IS ONE, because it is what a customer quotes in
    /// an email. An unfiled request says so instead of showing a blank, which is the
    /// same information the badge carries and is worth repeating here: the row is
    /// otherwise identical to a filed one.
    private func subtitle(for request: SupportRequestSummary) -> String {
        let when = ContactDates.readable(request.createdAt)
        guard let key = request.issueKey else { return "\(SupportCopy.unfiledStatus) · \(when)" }
        return "\(key) · \(when)"
    }

    // MARK: - Actions

    private var subjectBinding: Binding<String> {
        Binding(get: { model.draftSubject }, set: { model.editSubject($0) })
    }

    private var messageBinding: Binding<String> {
        Binding(get: { model.draftMessage }, set: { model.editMessage($0) })
    }

    private func submit() {
        Task { await model.submit() }
    }

    private func reload() {
        Task { await model.load() }
    }
}
