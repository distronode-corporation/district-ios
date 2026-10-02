import DistrictModel
import SwiftUI

/// One support request and its conversation with Distronode.
///
/// ⛔ THE THREAD IS SHOWN IN FULL, WHICH IS CORRECT HERE AND WRONG ONE SURFACE OVER.
/// `/api/internal/support-lookup` — the VOICE path — returns status and never a
/// summary, a description or a comment body, because a phone call is authenticated by
/// caller ID and caller ID is spoofable. This screen runs under the operator's own
/// session bearer inside an authenticated app and is workspace-scoped server-side, so
/// withholding the conversation would make it useless without protecting anything.
///
/// ⛔ NEITHER WRITE RE-ARMS ITSELF AFTER AN AMBIGUOUS FAILURE. Both post a PUBLIC
/// comment into a thread the customer reads, so a one-tap repeat after a lost response
/// risks a duplicate reply or a second "Closed at the requester's request by …" note.
/// The rule is ``SupportResubmit``; the button reads its answer off the write state.
///
/// ⚠️ THERE IS NO REOPEN, HERE OR SERVER-SIDE, because the desk's workflow exposes no
/// single unambiguous transition back out of `done`. Replying on a closed request is
/// the supported path and the placeholder says so.
struct SupportThreadView: View {
    @State private var model: SupportThreadModel

    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?, key: String) {
        _model = State(
            initialValue: SupportThreadModel(
                container: container,
                workspaceId: workspaceId,
                role: role,
                key: key
            )
        )
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DistrictSpacing.row) {
                content
            }
            .padding(DistrictSpacing.gutter)
            .districtReadableWidth()
        }
        .navigationTitle(SupportCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.thread {
        case .loading:
            LoadingView(message: SupportCopy.threadLoading)
        case let .ready(detail):
            headerCard(detail)
            conversation
            composer(detail)
        case let .failed(failure):
            SupportCard {
                Text(SupportCopy.threadFailed)
                    .font(DistrictType.titleSmall)
                    .foregroundStyle(colors.foreground)
                FailureView(failure: failure, onRetry: reload)
            }
        }
    }

    // MARK: - The header

    private func headerCard(_ detail: SupportRequestDetail) -> some View {
        SupportCard(eyebrow: detail.issueKey ?? SupportCopy.unfiledStatus) {
            Text(detail.subject)
                .font(DistrictType.titleLarge)
                .foregroundStyle(colors.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Text(SupportCopy.opened(WireDate.display(detail.createdAt)))
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            HStack(spacing: DistrictSpacing.hairline) {
                SupportChips(source: detail.source, region: detail.region)
                DistrictBadge(
                    text: model.statusName,
                    tone: SupportChrome.tone(for: statusCategory(detail))
                )
            }
            SupportWriteNotice(state: model.close, onDismiss: { model.dismissNotices() })
            if model.canClose {
                Button(model.close.isSending ? SupportCopy.closing : SupportCopy.close) {
                    closeRequest()
                }
                .buttonStyle(.districtSecondary)
                .disabled(model.close.isSending)
            }
        }
    }

    /// ⛔ THE LOCAL CLOSE OVERRIDES THE SERVER'S CATEGORY ONCE IT HAS HAPPENED, and it
    /// uses the canonical spelling the server stores so an optimistic badge and
    /// the next read cannot disagree about the same ticket.
    private func statusCategory(_ detail: SupportRequestDetail) -> String {
        model.closedStatusName == nil ? detail.statusCategory : SupportStatusCategory.resolved
    }

    // MARK: - The conversation

    /// ⛔ AN EMPTY THREAD IS A STATE AND NOT A FAILURE. The description the customer
    /// typed is the ticket's own body rather than a message, so the commonest thread a
    /// new customer opens has nothing in it.
    @ViewBuilder
    private var conversation: some View {
        if model.messages.isEmpty {
            Text(SupportCopy.threadEmpty)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ForEach(model.messages, id: \.id) { message in
                messageCard(message)
            }
        }
    }

    /// ⛔ THE AUTHOR LINE IS THE SERVER'S STRING AND THE ALIGNMENT COMES FROM THE
    /// ROLE, WHICH ARE TWO DIFFERENT QUESTIONS. `author` is display copy the route
    /// substitutes ("Distronode Support" or "You") and never the vendor agent's real
    /// name; `knownRole` is what says which side of the conversation this is. ⚠️ An
    /// unknown role is laid out NEUTRALLY rather than defaulting to either side:
    /// guessing `customer` would draw a message the workspace did not write as though
    /// they had, and guessing `agent` would put words in Distronode's mouth.
    private func messageCard(_ message: SupportMessage) -> some View {
        SupportCard {
            HStack(spacing: DistrictSpacing.tight) {
                Text(message.author)
                    .font(DistrictType.labelSmall)
                    .foregroundStyle(tone(for: message).ink(colors))
                Spacer(minLength: 0)
                Text(WireDate.display(message.createdAt))
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
                    .lineLimit(1)
            }
            // ⛔ PLAIN TEXT. The desk stores Atlassian's own rendering and the server
            // sends it as-is; nothing here may interpret it as markup.
            Text(message.body)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tone(for message: SupportMessage) -> Tone {
        switch message.knownRole {
        case .agent: .district
        case .customer: .neutral
        case nil: .neutral
        }
    }

    // MARK: - Replying

    /// ⛔ THE BOX IS WITHHELD UNTIL THE REQUEST IS FILED. A request between its local
    /// claim and the Atlassian call has no thread to post into, and the route answers
    /// 409 rather than accepting a message it would then drop — so offering the field
    /// would invite somebody to type a message that cannot be sent.
    @ViewBuilder
    private func composer(_ detail: SupportRequestDetail) -> some View {
        if !detail.filed {
            SupportCard {
                Text(SupportCopy.notFiledYet)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if model.canWrite {
            SupportCard {
                SettingsField(
                    label: SupportCopy.replyLabel,
                    text: replyBinding,
                    enabled: !model.reply.isSending,
                    multiline: true
                )
                Text(replyHint)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                SupportWriteNotice(state: model.reply, onDismiss: { model.dismissNotices() })
                HStack(spacing: DistrictSpacing.tight) {
                    Text(SupportCopy.sla)
                        .font(DistrictType.caption)
                        .foregroundStyle(colors.mutedForeground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(model.reply.isSending ? SupportCopy.replySending : SupportCopy.replySend) {
                        sendReply()
                    }
                    .buttonStyle(.districtPrimary)
                    .disabled(!model.canReply)
                }
            }
        }
    }

    /// ⚠️ A RESOLVED REQUEST GETS A DIFFERENT INVITATION, because replying is the ONLY
    /// way back: there is no reopen on this client or on the server.
    private var replyHint: String {
        model.isResolved ? SupportCopy.replyPlaceholderResolved : SupportCopy.replyPlaceholder
    }

    // MARK: - Actions

    private var replyBinding: Binding<String> {
        Binding(get: { model.draftReply }, set: { model.editReply($0) })
    }

    private func sendReply() {
        Task { await model.sendReply() }
    }

    private func closeRequest() {
        Task { await model.closeRequest() }
    }

    private func reload() {
        Task { await model.load() }
    }
}
