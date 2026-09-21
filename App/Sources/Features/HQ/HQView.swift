import DistrictModel
import SwiftUI

/// District HQ: the agentic console, and the two-step gate in front of every change it
/// proposes.
///
/// ⛔ THE TRANSCRIPT IS DRAWN FROM ITS OWN LIST, NOT FROM THE CONSOLE STATE. A failed
/// turn must leave the conversation on screen: the route is stateless and the server
/// keeps none of it, so a screen that blanked on failure would destroy the only copy.
///
/// ⛔ HQ IS OTHERWISE READ-ONLY, AND THE CONFIRM IS THE ONLY MUTATION REACHABLE FROM
/// HERE. There is no edit, no delete and no second button that writes; every change goes
/// through a proposal the operator read and approved. Adding a shortcut that wrote
/// anything directly would be a mutation with no summary in front of it.
///
/// ⛔ AND THE COMPOSER STAYS OPEN FOR EVERY ROLE, INCLUDING `viewer`. Reads admit
/// viewers; only writes do not, and the server declines those inside the tool executor
/// before a proposal is ever made, so a viewer simply never sees a confirm card. Hiding
/// the input from them would remove the half of the feature they are entitled to.
///
/// ⚠️ NO `NavigationStack` OF ITS OWN. ``ShellView`` provides one per tab and registers
/// `navigationDestination(for: Route.self)` on it exactly once.
struct HQView: View {
    @State private var model: HQModel

    /// ⚠️ THE DRAFT LIVES ON THE VIEW, NOT ON THE MODEL, WHICH IS THE OPPOSITE CALL FROM
    /// ``ComposerBar``. That one routes every keystroke through the model because the
    /// model arms an autosave from it; nothing here persists a draft, so a second copy
    /// of the text would be a second copy for no reason.
    @State private var draft = ""

    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        // ⚠️ `State(initialValue:)` in `init`, as every other model-owning screen does:
        // building it in `body` would be a new model, and a new transcript, on every
        // redraw.
        _model = State(
            initialValue: HQModel(container: container, workspaceId: workspaceId, role: role)
        )
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            footer
        }
        .navigationTitle(HQCopy.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - The conversation

    /// ⚠️ AN EMPTY CONSOLE IS AN INVITATION, NOT A FAILURE. Every workspace opens this
    /// screen with nothing in it, so the state has to say what the console can answer
    /// rather than looking like a load that did not happen.
    @ViewBuilder
    private var transcript: some View {
        if model.messages.isEmpty {
            EmptyStateView(
                systemImage: "sparkles",
                title: HQCopy.emptyTitle,
                message: HQCopy.empty
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DistrictSpacing.tight) {
                    ForEach(model.messages) { message in
                        HQBubble(message: message)
                    }
                }
                .padding(DistrictSpacing.gutter)
                .districtReadableWidth()
            }
        }
    }

    // MARK: - Everything below the conversation

    /// ⚠️ THE CARD, THE FAILURE AND THE COMPOSER SHARE ONE FOOTER so the proposal is
    /// always immediately above the control that applies it. A confirm card floating in
    /// the transcript would scroll away from its own buttons.
    private var footer: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            thinkingRow
            confirmCard
            promptFailure
            composer
        }
        .padding(DistrictSpacing.gutter)
        // ⚠️ THE COMPOSER IS CAPPED TO THE TRANSCRIPT'S COLUMN AND ITS BAND IS NOT, so
        // on a wide layout the field sits under the conversation it answers.
        .districtReadableWidth()
        .background(colors.surface)
    }

    @ViewBuilder
    private var thinkingRow: some View {
        if model.state.isThinking {
            Text(HQCopy.thinking)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
        }
    }

    /// ⚠️ DRAWN FOR `confirming`, `applying` AND `confirmFailed` alike, so the operator
    /// can always see WHAT is being applied, including after it failed, where the
    /// summary is the only record of what was attempted.
    @ViewBuilder
    private var confirmCard: some View {
        if let pending = model.state.pendingWrite {
            HQConfirmCard(model: model, pending: pending)
        }
    }

    /// ⚠️ A PROMPT FAILURE, NEVER A CONFIRM ONE. The second belongs on the card beside
    /// the summary it was refused for; putting both here would detach a refusal from the
    /// change it refused.
    @ViewBuilder
    private var promptFailure: some View {
        if let failure = model.state.promptFailure {
            HStack(alignment: .top, spacing: DistrictSpacing.tight) {
                Text(failure.message)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // ⚠️ OFFERED ONLY WHEN RETRYING COULD HONESTLY CHANGE THE ANSWER. A
                // contract mismatch and a role refusal both come back identical.
                if case .retry = failure.action {
                    Button(HQCopy.retry) { retry() }
                        .buttonStyle(.districtGhost)
                }
            }
        }
    }

    /// ⛔ CLOSED WHILE A PROPOSAL IS UNANSWERED, AND IT SAYS SO. Sending a prompt over a
    /// `confirming` or `confirmFailed` state reassigned the console state and destroyed
    /// the card, the summary and the pending write — a loss with no undo, since none of
    /// it is in the transcript and the confirm route accepts only a proposal that came
    /// back from a prompt. Declining a change is Dismiss, deliberately; it must not also
    /// be "start typing".
    ///
    /// ⚠️ THE FIELD IS DISABLED TOO, NOT JUST SEND. A box that accepts text it will never
    /// send is the same silent no-op wearing a different control.
    private var composer: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            // ⚠️ THE WORD "Ask" APPEARS TWICE ON PURPOSE. The eyebrow is the visible
            // label; a `TextField`'s title is what VoiceOver reads as the field's name,
            // and dropping it to avoid the repeat leaves the control announced as "text
            // field" and nothing else. ``ComposerBar`` makes the same call.
            DistrictEyebrow(text: HQCopy.promptLabel)
            HStack(alignment: .bottom, spacing: DistrictSpacing.tight) {
                field
                Button(HQCopy.send) { send() }
                    .buttonStyle(.districtPrimary)
                    .disabled(!model.canAsk || isBlank)
            }
            blockedNote
        }
    }

    /// ⚠️ ONLY FOR THE PENDING-WRITE CASE. ``thinkingRow`` already explains the other
    /// state the composer is closed in, and two sentences for one greyed-out box would
    /// leave the operator working out which applies.
    @ViewBuilder
    private var blockedNote: some View {
        if model.state.isAwaitingDecision {
            Text(HQCopy.composerBlocked)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var field: some View {
        TextField(HQCopy.promptLabel, text: $draft, axis: .vertical)
            .lineLimit(1 ... 5)
            .disabled(!model.canAsk)
            .districtField()
            .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private var isBlank: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// ⚠️ THE BOX IS CLEARED BEFORE THE TURN IS SENT, and the model trims and refuses a
    /// blank one itself. Clearing afterwards would leave the question in the field for
    /// the length of a model run, where a second tap is the obvious thing to do.
    private func send() {
        let prompt = draft
        draft = ""
        Task { await model.ask(prompt) }
    }

    private func retry() {
        Task { await model.retry() }
    }
}

/// One line of the transcript.
///
/// ⚠️ ALIGNMENT CARRIES WHO SPOKE, the same way the Inbox thread does it: the operator
/// sits right on a tint of the accent, the console sits left on the muted fill.
///
/// ⛔ THE CONSOLE'S ANSWERS ARE MARKDOWN AND ARE RENDERED AS PLAIN TEXT, DELIBERATELY. A
/// half-implemented renderer that dropped a table row or mangled a list would misreport
/// the workspace's own data, which is the one thing this screen exists to state
/// accurately.
private struct HQBubble: View {
    let message: HQMessage

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        HStack(spacing: 0) {
            if fromPerson {
                Spacer(minLength: DistrictSpacing.section)
            }
            Text(message.text)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
                .textSelection(.enabled)
                .padding(DistrictSpacing.row)
                .background(bubbleFill, in: RoundedRectangle(cornerRadius: DistrictRadius.card))
            if !fromPerson {
                Spacer(minLength: DistrictSpacing.section)
            }
        }
        .frame(maxWidth: .infinity, alignment: fromPerson ? .trailing : .leading)
    }

    private var fromPerson: Bool {
        if case .person = message.speaker {
            return true
        }
        return false
    }

    private var bubbleFill: Color {
        fromPerson ? colors.district.opacity(DistrictColors.containerAlpha) : colors.muted
    }
}

/// The confirm gate: what would happen, that nothing has happened yet, and the two ways
/// out of it.
///
/// ⛔ THE SUMMARY IS THE SUBJECT, NEVER THE TOOL NAME. The server composes a sentence
/// from the real arguments ("Permanently DELETE the CRM contact …") and it is the only
/// description the operator gets; drawing `delete_contact` instead would be asking
/// somebody to approve an identifier.
///
/// ⛔ AND THE ARGUMENTS ARE NEVER SHOWN, EDITED OR REBUILT HERE. They are echoed back
/// verbatim by the repository; anything this view did to them would apply a change the
/// summary did not describe.
///
/// ⚠️ TAKES THE MODEL RATHER THAN SIX CLOSURES AND FLAGS. `swiftlint --strict` promotes
/// the default `function_parameter_count` warning at 5 to an error, and an `@Observable`
/// model read from a subview's body tracks exactly the properties that body reads.
private struct HQConfirmCard: View {
    let model: HQModel
    let pending: HqPendingWrite

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            DistrictEyebrow(text: HQCopy.confirmTitle)
            Text(pending.summary)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
            Text(noteText)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            viewerNotice
            failureLine
            controls
        }
        .padding(DistrictSpacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.card, in: RoundedRectangle(cornerRadius: DistrictRadius.card))
        .overlay {
            RoundedRectangle(cornerRadius: DistrictRadius.card)
                .strokeBorder(colors.border, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var failureLine: some View {
        if let failure = model.state.confirmFailure {
            Text(failure.message)
                .font(DistrictType.caption)
                .foregroundStyle(colors.destructive)
        }
    }

    /// ⛔ THE CONFIRM BUTTON IS DISABLED WHILE APPLYING. This is the tap that deletes a
    /// contact or sends a customer an email, and the route offers no idempotency key, so
    /// this guard and the model's own are the only things between a double tap and a
    /// repeated write.
    ///
    /// ⚠️ DISMISS IS ALWAYS OFFERED AND IS NEVER THE ONLY WAY OUT for a role that can
    /// apply. The operator must be able to decline as easily as accept, which is also
    /// why this card is not a modal: the transcript stays readable behind it.
    private var controls: some View {
        HStack(spacing: DistrictSpacing.row) {
            if model.canConfirm {
                Button(confirmLabel) { confirm() }
                    .buttonStyle(.districtPrimary)
                    .disabled(model.state.isApplying)
            }
            Button(HQCopy.confirmDismiss) { model.dismissPending() }
                .buttonStyle(.districtGhost)
                .disabled(model.state.isApplying)
        }
        .padding(.top, DistrictSpacing.hairline)
    }

    /// ⛔ "Nothing has been changed yet." STOPS BEING TRUE THE MOMENT A CONFIRM FAILS,
    /// so the card stops saying it there, beside a button that already reads "Confirm
    /// again" for exactly this reason. A failed confirm may already have executed
    /// server-side; that is why nothing retries one automatically, and a card asserting
    /// the opposite is what makes a second press look free. ⚠️ Hoisted to `String` for
    /// the reason the rest of this file records about ternaries handed to `Text`.
    private var noteText: String {
        model.state.confirmFailure == nil ? HQCopy.confirmNote : HQCopy.confirmFailedNote
    }

    /// ⚠️ SAYS "Confirm again" AFTER A REFUSAL. A failed confirm may already have
    /// executed server-side, so the label has to make a second press read as a decision
    /// rather than as finishing something that did not start.
    private var confirmLabel: String {
        if model.state.isApplying {
            return HQCopy.applying
        }
        return model.state.confirmFailure == nil ? HQCopy.confirmApply : HQCopy.confirmRetry
    }

    @ViewBuilder
    private var viewerNotice: some View {
        if !model.canConfirm {
            Text(HQCopy.viewerCannotConfirm)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func confirm() {
        Task { await model.confirmPending() }
    }
}
