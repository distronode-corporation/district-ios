import DistrictModel
import SwiftUI

/// The automation monitor: is the SDR campaign running, which workflows exist, and what
/// did they do.
///
/// ⛔ A MONITOR, NOT A SETTINGS SECTION, AND THE DISTINCTION IS PURPOSE RATHER THAN
/// SUBJECT. Everything under the workspace-settings hub is a FORM whose save replaces
/// stored configuration, and every route behind that hub excludes `viewer` including the
/// read. Three of this screen's four routes admit viewers, nothing on it is authored, and
/// the question it answers ("did the follow-up actually go out") belongs beside Analytics
/// and HQ. Filing it under settings would have hidden it from the role most likely to be
/// asked to check.
///
/// ⚠️ TWO CONTROLS, BOTH ROLE-GATED, AND THEY ARE GATED DIFFERENTLY. Both PATCH routes
/// exclude `viewer` while every read admits one. The workflow switch is DISABLED for a
/// viewer, because the state is the content they came for and must stay visible; the
/// campaign button is ABSENT, because the card's caption already says in words who can
/// change it.
///
/// ⚠️ NO `NavigationStack` OF ITS OWN. ``ShellView`` provides one per tab and registers
/// `navigationDestination(for: Route.self)` on it exactly once.
struct WorkflowsView: View {
    @State private var model: WorkflowsModel

    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        _model = State(
            initialValue: WorkflowsModel(container: container, workspaceId: workspaceId, role: role)
        )
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DistrictSpacing.row) {
                campaignSection
                toggleFailureStrip
                DistrictEyebrow(text: WorkflowsCopy.section)
                    .padding(.top, DistrictSpacing.tight)
                listSection
            }
            .padding(DistrictSpacing.gutter)
            .districtReadableWidth()
        }
        .navigationTitle(WorkflowsCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        // ⚠️ TWO TASKS, NOT ONE. Each read starts on its own and settles into its own
        // state, so neither waits for the other and neither can fail the other.
        .task { await model.loadCampaign() }
        .task { await model.loadWorkflows() }
        // ⛔ ATTACHED AT THE ROOT SO IT SURVIVES THE LIST REDRAWING UNDERNEATH IT. A
        // dialog declared inside a row would be torn down when that row left the
        // composition, which on a phone is one flick away from a confirmation vanishing
        // mid-read.
        .confirmationDialog(
            campaignPrompt,
            isPresented: campaignConfirmBinding,
            titleVisibility: .visible
        ) {
            Button(campaignConfirmLabel) { commitCampaignChange() }
            Button(WorkflowsCopy.campaignCancel, role: .cancel) {}
        }
    }

    // MARK: - The campaign card

    /// ⚠️ A CAMPAIGN READ THAT FAILED DOES NOT BLOCK THE LIST BELOW IT. The two are
    /// separate requests against separate data layers, so this renders its own failure
    /// inline rather than taking over the screen.
    @ViewBuilder
    private var campaignSection: some View {
        switch model.campaign {
        case .loading:
            SkeletonBlock(height: DistrictSpacing.header)
        case let .ready(status):
            SdrCampaignCard(model: model, status: status)
        case let .failed(failure):
            WorkflowFailureCard(
                title: WorkflowsCopy.campaignFailed,
                failure: failure,
                onRetry: reloadCampaign
            )
        }
    }

    // MARK: - The workflow list

    @ViewBuilder
    private var listSection: some View {
        switch model.list {
        case .loading:
            skeleton
        case let .ready(workflows):
            rows(workflows)
        case let .failed(failure):
            WorkflowFailureCard(
                title: WorkflowsCopy.listFailed,
                failure: failure,
                onRetry: reloadWorkflows
            )
        }
    }

    private var skeleton: some View {
        VStack(spacing: DistrictSpacing.row) {
            ForEach(0 ..< 3, id: \.self) { _ in
                SkeletonBlock(height: 56)
            }
        }
    }

    /// ⛔ AN EMPTY LIST IS NOT A FAILURE AND MUST NOT LOOK LIKE ONE. Most workspaces have
    /// never created a workflow, and the copy points at where one is authored rather than
    /// implying something was lost.
    @ViewBuilder
    private func rows(_ workflows: [WorkflowListItem]) -> some View {
        if workflows.isEmpty {
            EmptyStateView(
                systemImage: "bolt.badge.clock",
                title: WorkflowsCopy.emptyTitle,
                message: WorkflowsCopy.emptyBody
            )
        } else {
            ForEach(workflows, id: \.id) { workflow in
                VStack(alignment: .leading, spacing: 0) {
                    WorkflowRowView(model: model, workflow: workflow)
                    if model.expanded == workflow.id {
                        RunHistoryPanel(model: model, workflowId: workflow.id)
                    }
                    DistrictRowDivider()
                }
            }
        }
    }

    // MARK: - The refused toggle

    /// ⛔ ALONGSIDE THE LIST, NEVER INSTEAD OF IT. The row it was refused on has already
    /// gone back to the server's value, so the list on screen is the truth and this
    /// explains why it did not move.
    @ViewBuilder
    private var toggleFailureStrip: some View {
        if let failure = model.toggleFailure {
            HStack(alignment: .top, spacing: DistrictSpacing.tight) {
                Text(failure.message)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(WorkflowsCopy.dismiss) { model.dismissToggleFailure() }
                    .buttonStyle(.districtGhost)
            }
        }
    }

    // MARK: - The confirmation

    /// ⚠️ BOTH HALVES READ FROM ``WorkflowsModel/campaignConfirm``, so the sentence and
    /// the button describe the value that will actually be written.
    private var campaignPrompt: String {
        guard let confirm = model.campaignConfirm else { return "" }
        return confirm.enable ? WorkflowsCopy.campaignResumePrompt : WorkflowsCopy.campaignPausePrompt
    }

    private var campaignConfirmLabel: String {
        guard let confirm = model.campaignConfirm else { return WorkflowsCopy.campaignCancel }
        return confirm.enable ? WorkflowsCopy.campaignResume : WorkflowsCopy.campaignPause
    }

    /// ⚠️ THE MODEL OWNS WHETHER THE DIALOG IS UP, so a reload that drops the pending
    /// confirmation closes it rather than leaving a sheet asking about a state that has
    /// been replaced.
    private var campaignConfirmBinding: Binding<Bool> {
        Binding(
            get: { model.campaignConfirm != nil },
            set: { presented in
                guard !presented else { return }
                model.dismissCampaignConfirm()
            }
        )
    }

    // MARK: - Actions

    private func commitCampaignChange() {
        Task { await model.confirmCampaignChange() }
    }

    /// ⚠️ EACH RETRY RE-RUNS ONLY ITS OWN READ. Retrying the campaign must not blank a
    /// workflow list that answered correctly, which a shared reload would do.
    private func reloadCampaign() {
        Task { await model.loadCampaign() }
    }

    private func reloadWorkflows() {
        Task { await model.loadWorkflows() }
    }
}

/// One card area's own failure, with a retry only when retrying could help.
///
/// ⚠️ A CARD, NOT A WHOLE-SCREEN STATE, exactly as ``AnalyticsCardFailure`` is: the other
/// read on this screen may have answered fine, and replacing everything with one message
/// would discard a correct answer already on screen.
///
/// ⛔ THE RETRY IS OFFERED ONLY WHEN ``FailureText`` SAYS SO. A role refusal and a
/// contract mismatch produce the identical failure on every attempt, and a button that
/// cannot work reads as a broken app.
struct WorkflowFailureCard: View {
    let title: String
    let failure: FailureText
    let onRetry: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            Text(title)
                .font(DistrictType.titleSmall)
                .foregroundStyle(colors.foreground)
            Text(failure.message)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
            if case .retry = failure.action {
                Button(WorkflowsCopy.retry, action: onRetry)
                    .buttonStyle(.districtSecondary)
            }
        }
        .padding(DistrictSpacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.card, in: RoundedRectangle(cornerRadius: DistrictRadius.card))
        .overlay {
            RoundedRectangle(cornerRadius: DistrictRadius.card)
                .strokeBorder(colors.border, lineWidth: 1)
        }
    }
}
