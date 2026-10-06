import DistrictModel
import SwiftUI

/// One call in full.
///
/// ⚠️ NO RECORDING PLAYER ANY MORE, and with it no `import AVKit`: nothing is recorded
/// in any region and the server retired the recording route on 2026-10-03.
struct CallDetailView: View {
    let workspaceId: String
    let callId: String

    /// ⛔ STORED, BECAUSE ``ReportSheet`` BUILDS ITS OWN MODEL. A call transcript is
    /// user-generated content — the caller spoke the words — so App Store Review
    /// Guideline 1.2 requires a way to flag it. See the ⛔ on ``ReportContentModel``.
    private let container: AppContainer

    @State private var model: CallDetailModel

    /// ⚠️ THE SHEET'S PRESENTATION LIVES ON THE SCREEN, not in the toolbar item: a
    /// `ToolbarContent` cannot carry a `.sheet`.
    @State private var reporting = false

    init(container: AppContainer, workspaceId: String, callId: String) {
        self.workspaceId = workspaceId
        self.callId = callId
        self.container = container
        _model = State(
            initialValue: CallDetailModel(container: container, workspaceId: workspaceId, callId: callId)
        )
    }

    var body: some View {
        content
            .navigationTitle("Call")
            .navigationBarTitleDisplayMode(.inline)
            // ⛔ `.contain` FIRST, or this identifier is inherited by the transcript
            // and every card and none of them can be addressed. Same trap
            // `SignInView`'s root documents, measured there rather than reasoned
            // about.
            // ⚠️ `A11yID.Calls.detailRoot`, `.transcript` AND `.showTranscript` ARE
            // ADDRESSED BY LITERAL in `ReviewRecordingTests`, inside an
            // `if waitForExistence(timeout: 3)`, so an identifier missing here does
            // not fail that test: its transcript step silently skips.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(A11yID.Calls.detailRoot)
            .task { await model.load() }
            // ⛔ THE GUIDELINE 1.2 FLAG. A transcript is the caller's own words, so
            // the screen that shows one has to offer a way to report it. ⚠️ There is
            // NO block control here: blocking is a property of a CONTACT, and a call
            // row carries a number that may never have resolved to one — the Contacts
            // tab and the inbox thread are where that decision belongs.
            .toolbar { reportItem }
            .sheet(isPresented: $reporting) {
                ReportSheet(container: container, workspaceId: workspaceId, target: .call(callId: callId))
            }
    }

    /// ⚠️ A MENU RATHER THAN A BARE BUTTON, with one item in it. The thread screen's
    /// moderation control is a menu because it has two, and a reviewer watching one
    /// recording should find the same affordance in the same place on both screens.
    private var reportItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button(ReportCopy.reportCall) { reporting = true }
                    .accessibilityIdentifier(A11yID.Calls.report)
            } label: {
                // ⚠️ A WORD, NOT AN SF SYMBOL: `A11yImageTests` requires every
                // symbol to carry an accessibility decision, and an ellipsis glyph
                // says nothing about what is behind it. ⛔ Naming that constructor
                // in a comment is what the gate counts — see the ⛔ in
                // `ThreadModerationMenu`.
                Text("Manage")
            }
            .accessibilityIdentifier(A11yID.Calls.detailMenu)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            LoadingView(message: "Loading call…")
        case let .content(call):
            CallDetailContentView(call: call, model: model)
        case let .failed(failure):
            FailureView(failure: failure, onRetry: reload)
        }
    }

    private func reload() {
        Task { await model.load() }
    }
}

/// The loaded call.
private struct CallDetailContentView: View {
    let call: CallSummary
    let model: CallDetailModel

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    /// ⛔ THE SAME MAPPER THE LOG USES. Deriving these inline is what let the other
    /// client's two call screens disagree about the duration; see ``CallDisplay``.
    private var display: CallDisplay {
        CallDisplay(call)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                header
                // ⛔ `display.aiSummaryText`, NEVER `call.aiSummary`. The wire field
                // is never empty and is often a marker: every outbound softphone
                // call carries the literal "direct:softphone" there, permanently,
                // and it would print under this heading. See ``CallNarrative``.
                card("AI summary", display.aiSummaryText)
                summaryNote
                card("Sentiment", call.sentiment)
                card("Outcome", call.disposition)
                transferCard
                followUpCard
                analysisCards
                transcriptSection
            }
            .padding(DistrictSpacing.gutter)
            .districtReadableWidth()
        }
        // ⛔ THE LIVE TRANSCRIPT'S SOCKET RUNS ONLY WHILE THIS SCREEN IS SHOWN AND THE APP IS IN
        // FRONT: opened on appearing and on becoming active, closed on disappearing and on
        // going to the background. `.inactive` (a pulled-down notification centre, the app
        // switcher) keeps it, since the screen is still in view.
        .onAppear {
            if scenePhase == .active {
                model.live?.activate()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.live?.activate()
            case .background: model.live?.deactivate()
            default: break
            }
        }
        .onDisappear { model.live?.deactivate() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(display.callerLabel)
                .font(DistrictType.headline)
                .foregroundStyle(colors.foreground)
            Text(display.subtitle)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
            DistrictBadge(text: display.statusLabel, tone: display.statusTone)
                .padding(.top, DistrictSpacing.hairline)
        }
    }

    // MARK: - Cards

    /// ⚠️ Rendered only when the value is present AND not blank. Every one of these
    /// columns is nullable and the route passes them through untouched.
    ///
    /// ⚠️ THE SUMMARY CARD IS HANDED AN OPTIONAL, NOT THE RAW WIRE FIELD. The server
    /// substitutes "No summary available." rather than sending an empty string, so a
    /// blank guard on the wire field would never fire.
    @ViewBuilder
    private func card(_ label: String, _ value: String?) -> some View {
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            DetailFieldCard(label: label, value: value)
        }
    }

    /// What stands in for the summary card when there is no summary.
    ///
    /// ⛔ IT SAYS WHICH OF THE TWO IT IS. An absent summary and a summariser that
    /// failed read identically if both are rendered as nothing, and this screen is
    /// where an operator decides whether to go read the transcript. The wording
    /// lives on ``CallDisplay/aiSummaryNote`` beside the rest of this screen's copy.
    ///
    /// ⚠️ THE MUTED NOTE, NOT ``failureNote(_:)``. A failed summariser is a fact
    /// about the call rather than a failure of this request, and nothing here can
    /// retry it, so an alarming colour would offer an action that does not exist.
    @ViewBuilder
    private var summaryNote: some View {
        if let text = display.aiSummaryNote {
            note(text)
        }
    }

    @ViewBuilder
    private var transferCard: some View {
        if let status = call.transferStatus {
            card("Transfer", [status, call.transferReason].compactMap(\.self).joined(separator: " · "))
        }
    }

    /// ⚠️ THE WIRE KEY IS `sms`, NOT `smsBody`. The column is `followUpSMSBody` and
    /// the handler renames it on the way out. Present only when a follow-up was
    /// actually sent.
    @ViewBuilder
    private var followUpCard: some View {
        if let followUp = call.followUp {
            card("Follow-up sent", [followUp.email, followUp.sms].compactMap(\.self).joined(separator: "\n"))
        }
    }

    /// ⚠️ Every analysis field is optional because `Call.analysis` is an unstructured
    /// JSON column, so each list is rendered only when it actually has content.
    @ViewBuilder
    private var analysisCards: some View {
        if let analysis = call.analysis {
            listCard("Key points", analysis.keyPoints)
            listCard("Objections", analysis.objections)
            listCard("Topics", analysis.topics)
            listCard("Action items", analysis.actionItems)
        }
    }

    @ViewBuilder
    private func listCard(_ label: String, _ values: [String]?) -> some View {
        if let values, !values.isEmpty {
            DetailFieldCard(label: label, value: values.map { "• \($0)" }.joined(separator: "\n"))
        }
    }

    // MARK: - Transcript

    /// ⚠️ THE LIVE PANE WHILE IT CAN BE HAD, AND THE ON-DEMAND TRANSCRIPT OTHERWISE: a call
    /// that was not in progress when the screen loaded, one the server has no live
    /// transcript for (not answered by the assistant, ended over two minutes ago), or a
    /// socket that cannot be opened.
    @ViewBuilder
    private var transcriptSection: some View {
        if let live = model.live, !live.fallsBack {
            LiveTranscriptSection(model: live)
        } else {
            onDemandTranscript
        }
    }

    @ViewBuilder
    private var onDemandTranscript: some View {
        switch model.transcript {
        case .idle:
            Button("Show transcript") {
                Task { await model.loadTranscript() }
            }
            .buttonStyle(.districtSecondary)
            // ⚠️ THE IDENTIFIER `ReviewRecordingTests` ADDRESSES BY LITERAL.
            // Without it the recording's transcript step finds nothing and skips.
            .accessibilityIdentifier(A11yID.Calls.showTranscript)
        case .loading:
            ProgressView()
        case let .loaded(text):
            DetailFieldCard(label: "Transcript", value: text)
                .accessibilityIdentifier(A11yID.Calls.transcript)
        case .absent:
            note("No transcript for this call.")
        case let .failed(failure):
            failureNote(failure)
        }
    }

    // MARK: - Small pieces

    private func note(_ text: String) -> some View {
        Text(text)
            .font(DistrictType.bodySmall)
            .foregroundStyle(colors.mutedForeground)
    }

    private func failureNote(_ failure: FailureText) -> some View {
        Text(failure.message)
            .font(DistrictType.bodySmall)
            .foregroundStyle(colors.destructive)
    }
}
