import DistrictModel
import SwiftUI

/// The always-on SDR campaign: its state, and the one field this client may change.
///
/// ⛔ EXACTLY ONE FIELD IS WRITABLE HERE, AND THE CAPTION SAYS WHERE THE OTHER TWO ARE
/// CHANGED. `PATCH workspace/campaign-settings` rebuilds all three SDR fields from its
/// body and would wipe the goal text on a partial write; `PATCH
/// workspace/campaign-status` spreads the stored object and assigns one key, which is why
/// the pause is safe and the batch size and the goal stay web-only. Saying so is what
/// stops the single button reading as a half-built settings form.
///
/// ⛔ A VIEWER SEES THE STATE AND NO BUTTON. The GET admits `viewer` and the PATCH does
/// not, so the state is exactly what they came for and the control is the only thing
/// withheld. A disabled button here would be a second, weaker way of saying what the
/// viewer caption already says in words.
///
/// ⚠️ AN EMPTY CAMPAIGN IS A STATE, NEVER AN ERROR. A workspace that never opened the
/// campaigns tab and one that deliberately switched the campaign off are the SAME value
/// on the wire, so "Paused" has to be true of both: "Not set up" would be wrong for the
/// second and "Off" understates the first.
struct SdrCampaignCard: View {
    let model: WorkflowsModel
    let status: CampaignStatus

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            header
            // ⛔ NULL IS NOT ZERO. The settings route floors the stored batch size to at
            // least 1, so a "0" here would be a number nobody configured, printed against
            // a live outbound campaign.
            Text(status.sdrBatchSize.map { WorkflowsCopy.batchLine($0) } ?? WorkflowsCopy.campaignBatchUnset)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
            Text(status.sdrCampaignGoal ?? WorkflowsCopy.campaignNoGoal)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
            Text(model.canToggle ? WorkflowsCopy.campaignReadOnly : WorkflowsCopy.campaignReadOnlyViewer)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            control
            failureLine
        }
        .padding(DistrictSpacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.card, in: RoundedRectangle(cornerRadius: DistrictRadius.card))
        .overlay {
            RoundedRectangle(cornerRadius: DistrictRadius.card)
                .strokeBorder(colors.border, lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: DistrictSpacing.tight) {
            DistrictEyebrow(text: WorkflowsCopy.campaignLabel)
            Spacer(minLength: DistrictSpacing.tight)
            DistrictBadge(
                text: status.infiniteSdrEnabled ? WorkflowsCopy.campaignActive : WorkflowsCopy.campaignPaused,
                tone: status.infiniteSdrEnabled ? .success : .neutral
            )
        }
    }

    /// ⚠️ THE TARGET VALUE, NOT A TOGGLE SIGNAL. The label and the request are derived
    /// from the same expression, so a card rendered from a stale status cannot ask for one
    /// thing while saying another.
    ///
    /// ⚠️ DISABLED RATHER THAN HIDDEN WHILE A WRITE IS IN FLIGHT: the card must not appear
    /// to lose its only control for the length of a round trip.
    @ViewBuilder
    private var control: some View {
        if model.canToggle {
            Button(controlLabel) { model.requestCampaignChange(enable: !status.infiniteSdrEnabled) }
                .buttonStyle(controlStyle)
                .disabled(model.campaignPending)
                .padding(.top, DistrictSpacing.hairline)
        }
    }

    private var controlLabel: String {
        if model.campaignPending {
            return WorkflowsCopy.campaignWorking
        }
        return status.infiniteSdrEnabled ? WorkflowsCopy.campaignPause : WorkflowsCopy.campaignResume
    }

    /// ⚠️ A NAMED `DistrictButtonStyle` RATHER THAN A TERNARY INSIDE `.buttonStyle(_:)`.
    /// That modifier is generic over `ButtonStyle`, so two implicit member expressions in
    /// a ternary would ask the type checker to infer the generic parameter from a
    /// branchless context, the same class of inference question ``SchedulingBadge``
    /// records, and one that surfaces only in the full SwiftUI build.
    private var controlStyle: DistrictButtonStyle {
        status.infiniteSdrEnabled ? .districtSecondary : .districtPrimary
    }

    /// ⚠️ THE WRITE'S FAILURE, NOT THE READ'S, and it sits beside a status that is still
    /// the last one the server sent. A refused pause leaves the campaign exactly as it
    /// was, which is the answer the operator needs most at that moment.
    @ViewBuilder
    private var failureLine: some View {
        if let failure = model.campaignFailure {
            Text(failure.message)
                .font(DistrictType.caption)
                .foregroundStyle(colors.destructive)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One workflow: what fires it, how its last run went, and whether it is on.
///
/// ⛔ THE ROW EXPANDS AND THE SWITCH DOES NOT. Two actions on one row need two targets; a
/// switch that also expanded would make every attempt to read the history flip a live
/// workflow. That is why the text column is its own `Button` rather than the whole row
/// being wrapped in one.
///
/// ⛔ THE SWITCH IS DISABLED FOR A VIEWER RATHER THAN HIDDEN, which is the opposite call
/// from the workspace-settings entry on the Overview. There the whole destination is
/// hidden because every route behind it refuses a viewer and the screen would be empty.
/// Here the STATE is the content (a viewer opened this to find out whether the
/// follow-up automation is running), so removing the switch would remove the answer
/// along with the control.
///
/// ⚠️ AN UNRECOGNISED TRIGGER IS DRAWN BY ITS RAW WIRE VALUE. The server's vocabulary has
/// already grown once and an installed build has to keep drawing a workflow it does not
/// fully understand; see ``WorkflowTrigger/label(_:)``.
struct WorkflowRowView: View {
    let model: WorkflowsModel
    let workflow: WorkflowListItem

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        // ⛔ THE SWITCH AND THE RUN BADGE MOVE BELOW THE NAME AT AN ACCESSIBILITY
        // TEXT SIZE. `activeSwitch` carries `layoutPriority(1)` — deliberately, so
        // the control is never squeezed out of reach — which at AX5 means the name
        // and its trigger are what gets squeezed, to one or two characters each.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DistrictSpacing.tight))
            : AnyLayout(HStackLayout(spacing: DistrictSpacing.row))
        return layout {
            expandButton
            LatestRunBadge(workflow: workflow)
            activeSwitch
        }
        .padding(.vertical, DistrictSpacing.row)
        .frame(minHeight: 56)
    }

    private var expandButton: some View {
        Button { expand() } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(workflow.name)
                    .font(DistrictType.titleSmall)
                    .foregroundStyle(colors.foreground)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .truncationMode(.tail)
                Text(WorkflowTrigger.label(workflow.trigger))
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// ⛔ ONE TAP, ONE CALL, AND THE SWITCH IS ITS OWN WRITE'S PRISONER ONLY. It is
    /// disabled while ITS write is in flight rather than while any is: two switches touch
    /// two different rows and nothing re-reads, so they do not race.
    private var activeSwitch: some View {
        Toggle(workflow.name, isOn: activeBinding)
            .labelsHidden()
            .disabled(!model.canToggle || model.isToggling(workflow))
            .layoutPriority(1)
    }

    /// ⚠️ THE GETTER READS THE MODEL, NOT A LOCAL COPY. That is what makes the revert
    /// visible: a failed write drops the optimistic override and this getter starts
    /// answering the list's own value again.
    private var activeBinding: Binding<Bool> {
        Binding(
            get: { model.isActive(workflow) },
            set: { active in
                Task { await model.setActive(workflowId: workflow.id, active: active) }
            }
        )
    }

    private func expand() {
        Task { await model.toggleExpanded(workflow.id) }
    }
}

/// The last run's outcome, or the fact that there has not been one.
///
/// ⛔ "Never run" IS A REAL AND COMMON STATE AND IS SHOWN RATHER THAN LEFT BLANK.
/// `latestRun` is an explicit null for a workflow nobody has triggered yet, which is
/// every workflow for as long as it takes its trigger to fire; a blank would read as a
/// missing value rather than as an answer.
///
/// ⚠️ THE TIMESTAMP GOES THROUGH ``WireDate/display(_:in:)`` RATHER THAN A SECOND
/// PARSER. It already pays for the trap that an ISO-8601 parser rejects fractional
/// seconds unless told to expect them and rejects their ABSENCE when it is, so two
/// formats have to be tried, and it falls back to the raw string rather than blanking.
struct LatestRunBadge: View {
    let workflow: WorkflowListItem

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        if let run = workflow.latestRun {
            VStack(alignment: .trailing, spacing: 2) {
                DistrictBadge(text: run.status, tone: .forRunStatus(run.status))
                Text(WireDate.display(run.startedAt))
                    .font(DistrictType.labelSmall)
                    .foregroundStyle(colors.mutedForeground)
                    .lineLimit(1)
            }
        } else {
            DistrictBadge(text: WorkflowsCopy.neverRun, tone: .neutral)
        }
    }
}

/// One workflow's run history, fetched on expand.
///
/// ⛔ A FAILED PAGE KEEPS THE PAGES BEFORE IT. The rows already on screen are a correct
/// answer; a "load more" that failed shows its message and leaves them alone.
///
/// ⛔ AND A FAILED PAGE CARRIES ITS OWN RETRY, BECAUSE THE FIRST ONE HAS NO PAGE BEFORE
/// IT. The class comment on ``WorkflowsModel`` covers the page-two case and there is
/// nothing to fall back on at page one: `hasMore` is false, so the only button is not
/// drawn, and the cache entry the fetch left behind makes a re-expand a no-op. Without
/// this retry that state has no way out at all.
///
/// ⚠️ `hasMore` DECIDES WHETHER THE "load more" BUTTON EXISTS, and it is the SERVER's
/// flag rather than `runs.count < limit`. Deriving it here would end the list early
/// whenever a run was written between two requests.
struct RunHistoryPanel: View {
    let model: WorkflowsModel
    let workflowId: String

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private var history: WorkflowRunHistory? {
        model.runs[workflowId]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            DistrictEyebrow(text: WorkflowsCopy.runsHeading)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, DistrictSpacing.row)
    }

    @ViewBuilder
    private var content: some View {
        if let history, !history.loading || !history.runs.isEmpty {
            loaded(history)
        } else {
            SkeletonBlock(height: DistrictSpacing.header)
        }
    }

    @ViewBuilder
    private func loaded(_ history: WorkflowRunHistory) -> some View {
        // ⚠️ REACHABLE ONLY ONCE A READ SUCCEEDED, so it means this workflow has never
        // fired, never "we could not look", which is the failure line below.
        if history.runs.isEmpty, history.failure == nil {
            Text(WorkflowsCopy.runsEmpty)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
        }
        ForEach(history.runs, id: \.id) { run in
            RunCard(run: run)
        }
        failureLine(history)
        if history.hasMore {
            Button(WorkflowsCopy.runsMore) { loadMore() }
                .buttonStyle(DistrictButtonStyle(variant: .secondary, size: .small))
                .disabled(history.loading)
        }
    }

    /// ⛔ THE RETRY IS HERE BECAUSE "load more" COULD NEVER BE IT. That button is gated on
    /// `hasMore`, which the server only sets on a page that ARRIVED — so after a
    /// first-page failure this panel would have a message and no control whatsoever, and
    /// the entry left in the cache stops a re-expand fetching anything either. A failed
    /// page and a way to ask for it again belong on the same line.
    ///
    /// ⛔ OFFERED ONLY WHEN ``FailureText`` SAYS RETRYING COULD CHANGE THE ANSWER, the
    /// same rule ``WorkflowFailureCard`` follows. A role refusal and a contract mismatch
    /// come back identical every time, and a button that cannot work reads as a broken
    /// app rather than as a refusal.
    @ViewBuilder
    private func failureLine(_ history: WorkflowRunHistory) -> some View {
        if let failure = history.failure {
            Text(failure.message)
                .font(DistrictType.caption)
                .foregroundStyle(colors.destructive)
                .fixedSize(horizontal: false, vertical: true)
            if case .retry = failure.action {
                Button(WorkflowsCopy.retry) { retry() }
                    .buttonStyle(DistrictButtonStyle(variant: .secondary, size: .small))
                    .disabled(history.loading)
            }
        }
    }

    private func loadMore() {
        Task { await model.loadMoreRuns(workflowId) }
    }

    private func retry() {
        Task { await model.retryRuns(workflowId) }
    }
}

/// One run.
///
/// ⛔ THE WHOLE-RUN `error` AND THE PER-ACTION OUTCOMES ARE BOTH RENDERED, because a run
/// can carry either without the other. The engine can throw before any action executes,
/// which produces a `failed` run with an EMPTY `actionResults`. A card that showed only
/// the action rows would draw that as a failure with no explanation whatsoever.
///
/// ⚠️ `finishedAt` IS NULL FOR A RUN THAT DID NOT FINISH and the card says so rather than
/// leaving a gap where a time should be.
struct RunCard: View {
    let run: WorkflowRun

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            header
            // ⚠️ KEYED BY INDEX, WHICH IS NORMALLY WRONG AND IS RIGHT HERE. An action
            // result carries no id, two identical actions in one run are genuinely two
            // rows, and this array is fixed for the life of the card: nothing is
            // inserted, removed or reordered after the run that wrote it finished.
            ForEach(run.actionResults.indices, id: \.self) { index in
                actionRow(run.actionResults[index])
            }
            if let error = run.error {
                Text(error)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DistrictSpacing.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.card, in: RoundedRectangle(cornerRadius: DistrictRadius.card))
    }

    /// ⚠️ THREE FACTS ON ONE LINE IS A DEFAULT-SIZE LUXURY. A status badge and two
    /// formatted instants do not fit across a phone at an accessibility size, and
    /// the two timestamps are the pair a reader compares, so they stack rather than
    /// each losing half its characters.
    private var header: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DistrictSpacing.hairline))
            : AnyLayout(HStackLayout(spacing: DistrictSpacing.tight))
        return layout {
            DistrictBadge(text: run.status, tone: .forRunStatus(run.status))
            Text(WireDate.display(run.startedAt))
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(finishedLine)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
        }
    }

    private var finishedLine: String {
        guard let finished = run.finishedAt else { return WorkflowsCopy.runUnfinished }
        return WireDate.display(finished)
    }

    /// ⛔ THE `reason` IS THE MOST USEFUL LINE ON THE CARD. The engine attaches one when
    /// it SKIPS an action (no contact, no phone number, missing metadata), which is
    /// exactly the case where the outcome word alone tells an operator nothing they can
    /// act on.
    private func actionRow(_ action: WorkflowActionResult) -> some View {
        HStack(alignment: .top, spacing: DistrictSpacing.tight) {
            DistrictBadge(text: action.outcome, tone: .forActionOutcome(action.outcome))
            VStack(alignment: .leading, spacing: 2) {
                Text(action.type)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.foreground)
                if let reason = action.reason {
                    Text(reason)
                        .font(DistrictType.caption)
                        .foregroundStyle(colors.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
