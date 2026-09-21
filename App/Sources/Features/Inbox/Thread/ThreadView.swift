import DistrictData
import DistrictModel
import SwiftUI

/// One conversation, with a reply box.
///
/// ⛔ THIS RENDERS CALLS AS WELL AS MESSAGES, AND FILTERING THEM OUT WOULD BE A BUG.
/// The server interleaves SMS, email and calls because an operator reading a thread
/// needs to see that the customer PHONED between two texts. Dropping the call leaves
/// an unexplained gap and, worse, hides a missed call, which is the one event in a
/// thread that needs acting on.
///
/// ⛔ NO `NavigationStack` HERE. ``ShellView`` provides one per tab and registers
/// `navigationDestination(for: Route.self)` on it exactly once.
struct ThreadView: View {
    private let title: String?

    /// ⛔ THE WHOLE MODERATION IDENTITY IN ONE STORED VALUE, BUILT IN `init`. See the
    /// ⛔ on ``ThreadModerationContext``.
    private let moderation: ThreadModerationContext

    @State private var model: ThreadModel

    /// ⚠️ THE MENU'S TWO PRESENTATIONS LIVE ON THE SCREEN, NOT IN THE TOOLBAR ITEM.
    /// `.confirmationDialog` and `.sheet` are `View` modifiers and a `ToolbarContent`
    /// cannot carry one; see the ⛔ on ``ThreadModerationModifier``.
    @State private var reporting = false
    @State private var confirmingBlock = false

    /// ⚠️ READ HERE RATHER THAN IN ``ThreadModel``, BECAUSE IT IS THE ENVIRONMENT AND THE
    /// MODEL IS NOT A VIEW. `SchedulingView` reads the same value for its polling gate.
    @Environment(\.scenePhase) private var scenePhase

    /// ⚠️ THE SCREEN POPS ITSELF ON A SUCCESSFUL BLOCK: Apple asks that blocking take
    /// the content out of view immediately, and the thread is content.
    @Environment(\.dismiss) private var dismiss

    init(
        container: AppContainer,
        workspaceId: String,
        role: WorkspaceRole?,
        threadKey: String,
        replyTargets: [ReplyTarget],
        title: String?
    ) {
        self.title = title
        // ⚠️ `allowsMutation(role)` RATHER THAN `model.canMutate`: the same
        // expression on the same input (the model computes it in its own `init` from
        // this very parameter), and reading it off the model would force this value
        // to be built in `body`.
        moderation = ThreadModerationContext(
            container: container,
            workspaceId: workspaceId,
            threadKey: threadKey,
            title: title,
            canModerate: WorkspaceRole.allowsMutation(role)
        )
        _model = State(initialValue: ThreadModel(
            container: container,
            workspaceId: workspaceId,
            role: role,
            threadKey: threadKey,
            replyTargets: replyTargets
        ))
    }

    var body: some View {
        content
            // ⚠️ THE COUNTERPART NAME, WHICH THE ROUTE CARRIES BECAUSE THE LIST
            // RESOLVED IT. It is Optional because a restored back stack can hold a
            // destination built before a name was known; the fallback is a neutral
            // noun rather than "Unknown", which would assert the customer has no
            // name when the truth is that this screen was not told it.
            .navigationTitle(title ?? "Conversation")
            .navigationBarTitleDisplayMode(.inline)
            // ⛔ `.contain` FIRST, or every bubble and the composer inherit this
            // identifier. Same trap `SignInView`'s root documents.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(A11yID.Inbox.threadRoot)
            // ⛔ THE GUIDELINE 1.2 CONTROLS: menu, confirmation and report sheet in
            // ONE modifier (`ThreadModerationMenu.swift`). Block pops this screen,
            // because the inbox list stops containing the thread at once.
            .threadModeration(
                moderation,
                reporting: $reporting,
                confirmingBlock: $confirmingBlock,
                onBlocked: { dismiss() }
            )
            // ⚠️ THE TIMELINE AND THE SAVED DRAFT, IN THAT ORDER, AND THE ORDER IS
            // ``ThreadModel/open()``'s to state rather than this view's, because the
            // retry below has to run the same pair.
            .task { await model.open() }
            // ⛔ ON THE WAY OUT OF `.active` RATHER THAN ON `.background`. iOS moves a
            // scene to `.inactive` first (the app switcher, Control Centre, an incoming
            // call) and only then to `.background`, where it can be suspended and later
            // killed without running another line; starting the write at `.inactive` is
            // what gives it a fully scheduled process to finish in. Rationale for the
            // flush itself is on ``ThreadModel/flushDraft()``.
            //
            // ⚠️ NOT `.onDisappear`, WHICH IS A DIFFERENT AND STILL-OPEN CASE. Popping
            // this screen inside the debounce window also loses the last edit (the
            // `@State` model is torn down and the pending task's `[weak self]` is nil by
            // the time it fires), but `onDisappear` cannot tell a pop from a tab switch,
            // and a flush per tab switch spends the workspace's shared write budget.
            .onChange(of: scenePhase) { _, phase in
                guard phase != .active else { return }
                Task { await model.flushDraft() }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            skeleton
        case let .content(loaded):
            ThreadContentView(model: model, content: loaded, isEmpty: false)
        case let .empty(loaded):
            // ⚠️ THE COMPOSER STAYS. A thread with no history is still a thread
            // somebody can reply on; see the ⛔ on ``ThreadState``.
            ThreadContentView(model: model, content: loaded, isEmpty: true)
        case let .failed(failure):
            FailureView(failure: failure, onRetry: reload)
        }
    }

    /// ⚠️ SKELETON BUBBLES, NOT A CENTRED SPINNER. The content arriving has a known
    /// shape, so drawing that shape says what is loading and stops the layout
    /// jumping when it lands.
    private var skeleton: some View {
        VStack(spacing: DistrictSpacing.row) {
            ForEach(0 ..< 6, id: \.self) { _ in
                SkeletonBlock(height: 48)
            }
            Spacer(minLength: 0)
        }
        .padding(DistrictSpacing.gutter)
    }

    /// ⛔ ``ThreadModel/open()``, NOT ``ThreadModel/load()``. A screen whose first open
    /// failed has a composer that has never heard of the saved draft, and a retry that
    /// re-read only the timeline would leave it that way for the life of the screen.
    private func reload() {
        Task { await model.open() }
    }
}

/// The loaded thread: history above, composer below.
private struct ThreadContentView: View {
    let model: ThreadModel
    let content: ThreadContent
    let isEmpty: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            timeline
            // ⚠️ THE COMPOSER IS HIDDEN ENTIRELY, NOT DISABLED, WHEN THE ROLE OR THE
            // THREAD CANNOT CARRY A REPLY. A greyed-out box invites the operator to
            // work out why; a viewer's answer is that this seat never sends, and a
            // thread with no reachable address has nowhere for the text to go.
            if model.canReply {
                ComposerBar(model: model, content: content)
            }
        }
    }

    @ViewBuilder
    private var timeline: some View {
        if isEmpty {
            VStack(spacing: 0) {
                olderControl
                Spacer(minLength: 0)
                EmptyStateView(
                    systemImage: "bubble.left.and.bubble.right",
                    title: "Nothing in this thread",
                    message: "Messages and calls with this contact will appear here."
                )
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            events
        }
    }

    /// ⚠️ `defaultScrollAnchor(.bottom)` RATHER THAN A `ScrollViewReader` AND AN
    /// `onAppear` SCROLL. A conversation opens at its newest message; doing that by
    /// scrolling after layout means one visible frame at the top of the history,
    /// which reads as the screen jumping away from where the operator was looking.
    private var events: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                olderControl
                incompleteCaption
                ForEach(content.events) { event in
                    ThreadEventRow(event: event)
                }
            }
            .padding(.vertical, DistrictSpacing.row)
        }
        .defaultScrollAnchor(.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "Older messages" — the top of the thread, where the history keeps going.
    ///
    /// ⚠️ A LABELLED BUTTON RATHER THAN AN INFINITE-SCROLL TRIGGER. The top of a
    /// conversation is a place an operator arrives by scrolling up through a reply
    /// they are writing about; auto-fetching there moves the content under their
    /// finger every time they overshoot.
    ///
    /// ⛔ A FAILURE KEEPS THE BUTTON, and the row is drawn when the failure is set
    /// even if `hasMore` has since gone false, so a failed page can never be
    /// silently swallowed.
    @ViewBuilder
    private var olderControl: some View {
        if content.hasMore || content.olderFailure != nil {
            VStack(spacing: DistrictSpacing.hairline) {
                if let failure = content.olderFailure {
                    Text(failure.message)
                        .font(DistrictType.caption)
                        .foregroundStyle(colors.destructive)
                        .multilineTextAlignment(.center)
                }
                // ⚠️ THE LABEL CARRIES THE PROGRESS STATE, matching Sending… and
                // Drafting… below: the control is disabled while the page is in
                // flight, so the changed word is what explains it.
                Button(content.loadingOlder ? "Loading older…" : "Older messages") {
                    Task { await model.loadOlder() }
                }
                .buttonStyle(.districtGhost)
                .disabled(content.loadingOlder)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, DistrictSpacing.gutter)
            .padding(.bottom, DistrictSpacing.tight)
        }
    }

    /// ⛔ SAID OUT LOUD RATHER THAN SWALLOWED. Rows the reader could not parse are
    /// counted, not dropped silently, because a thread quietly missing somebody's
    /// reply is worse than one that admits it is incomplete.
    @ViewBuilder
    private var incompleteCaption: some View {
        if content.incompleteCount > 0 {
            Text("Part of this conversation could not be read, so some entries are missing.")
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, DistrictSpacing.gutter)
                .padding(.bottom, DistrictSpacing.tight)
        }
    }
}

/// One entry: a message bubble, or a call.
private struct ThreadEventRow: View {
    let event: ThreadEvent

    var body: some View {
        if event.isCall {
            CallEventRow(event: event)
        } else {
            MessageBubble(event: event)
        }
    }
}

/// ⚠️ ALIGNMENT CARRIES DIRECTION, and the tone carries the delivery status rather
/// than the direction. An outbound message is the workspace talking, so it sits
/// right in the accent; inbound is the customer and sits left on the muted fill.
/// Using the accent for both would make the conversation unreadable at a glance,
/// which is the only thing alignment is for.
private struct MessageBubble: View {
    let event: ThreadEvent

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        HStack {
            if event.isOutbound {
                Spacer(minLength: DistrictSpacing.header)
            }
            bubble
            if !event.isOutbound {
                Spacer(minLength: DistrictSpacing.header)
            }
        }
        .padding(.horizontal, DistrictSpacing.gutter)
        .padding(.vertical, DistrictSpacing.hairline)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            subject
            // ⚠️ THE BODY IS RENDERED EVEN WHEN EMPTY IS THE TRUTH. The server writes
            // `msg.body || ""`, so an MMS with only a picture is a legitimately blank
            // string; the attachments below are what carry it.
            Text(event.body)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
            footer
            attachments
        }
        .padding(DistrictSpacing.row)
        .background(fill, in: RoundedRectangle(cornerRadius: DistrictRadius.card))
    }

    /// Email only. An SMS has no subject and printing an empty line looks like a bug.
    @ViewBuilder
    private var subject: some View {
        if let subject = event.subject, !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(subject)
                .font(DistrictType.titleSmall)
                .foregroundStyle(colors.foreground)
        }
    }

    private var footer: some View {
        HStack(spacing: DistrictSpacing.hairline) {
            // ⛔ FORMATTED HERE, BECAUSE THE SERVER SENDS A MACHINE INSTANT. The
            // timeline's `timestamp` is a raw ISO-8601 string on both its branches,
            // not a label rendered in the operator's timezone, so printing it verbatim
            // puts `2026-08-15T14:20:00.000Z` under every bubble.
            // ``ContactDates/readable(_:)`` is reused rather than copied: it already pays
            // for the fractional-seconds parse that silently returns nil without it.
            Text(ContactDates.readable(event.timestamp))
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            // ⚠️ STATUS ONLY ON OUTBOUND. An inbound message's status is a receipt
            // artefact; on an outbound one it is the delivery answer the operator is
            // actually looking for after a send.
            if event.isOutbound, !event.status.isEmpty {
                DistrictBadge(text: event.status, tone: ThreadMessageTone.tone(for: event.status))
            }
            if !event.mediaUrls.isEmpty {
                DistrictBadge(text: attachmentLabel, tone: .info)
            }
        }
    }

    /// ⚠️ THE BADGE STAYS ALONGSIDE THE THUMBNAILS RATHER THAN BEING REPLACED BY
    /// THEM. A thumbnail that has not loaded, or cannot, would otherwise leave no
    /// indication that the message HAD an attachment, which is the one fact the
    /// operator must not lose.
    @ViewBuilder
    private var attachments: some View {
        if !event.mediaUrls.isEmpty {
            HStack(spacing: DistrictSpacing.hairline) {
                ForEach(event.mediaUrls, id: \.self) { url in
                    ThreadMediaThumbnail(url: url)
                }
            }
        }
    }

    /// ⚠️ SINGULAR AND PLURAL SPELLED OUT. "1 attachments" is the kind of detail
    /// that makes a product look unfinished.
    private var attachmentLabel: String {
        let count = event.mediaUrls.count
        return count == 1 ? "1 attachment" : "\(count) attachments"
    }

    private var fill: Color {
        event.isOutbound ? colors.district.opacity(DistrictColors.containerAlpha) : colors.muted
    }
}

/// A call, rendered as a centred event rather than a bubble.
///
/// ⛔ NOT A BUBBLE, BECAUSE A CALL IS NOT SOMETHING EITHER SIDE *SAID*. And a MISSED
/// call has no side at all, so putting it left or right would assert something
/// untrue about who spoke.
///
/// ⚠️ `direction` ON A CALL ROW IS AN OUTCOME, NOT A DIRECTION. The server's
/// timeline mapper ignores `Call.direction` and labels every non-failed call
/// `inbound`, reserving `missed` for failed and no-answer — so an outbound call
/// appears here as inbound, and nothing on this row may read as "you called them".
private struct CallEventRow: View {
    let event: ThreadEvent

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private var isMissed: Bool {
        event.direction == ThreadEventDirection.missed
    }

    var body: some View {
        VStack(spacing: DistrictSpacing.hairline) {
            HStack(spacing: DistrictSpacing.hairline) {
                DistrictBadge(text: isMissed ? "Missed call" : "Call", tone: isMissed ? .danger : .neutral)
                if let duration {
                    DistrictBadge(text: duration, tone: .neutral)
                }
                // ⛔ AN INDICATOR, NOT THE TRANSCRIPT. The text is deliberately not in
                // this payload, because transcripts would dominate the response on every
                // thread open. The call detail screen fetches it on demand.
                if event.hasTranscript {
                    DistrictBadge(text: "Transcript", tone: .info)
                }
            }
            // ⛔ THE SAME MACHINE INSTANT A MESSAGE BUBBLE CARRIES; see ``MessageBubble``.
            Text(ContactDates.readable(event.timestamp))
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            summary
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DistrictSpacing.gutter)
        .padding(.vertical, DistrictSpacing.tight)
    }

    /// The voice agent's own summary, when there is one. Far more useful in a thread
    /// than a duration, and the reason a call belongs here at all.
    @ViewBuilder
    private var summary: some View {
        if let summary = event.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(summary)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .multilineTextAlignment(.center)
        }
    }

    /// ⚠️ NIL FOR A MISSED CALL AND FOR A ZERO, because "0s" beside "Missed call"
    /// reads as a measurement rather than the absence of one.
    private var duration: String? {
        guard let seconds = event.durationSeconds, seconds > 0 else { return nil }
        guard seconds >= 60 else { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}
