import AVKit
import DistrictModel
import SwiftUI

/// One call in full.
///
/// ⚠️ `import AVKit` LIVES IN THIS FILE ONLY. The banned-import grep in CI
/// covers `Packages/DistrictCore/Sources`, where platform frameworks would break the
/// Linux tier; the app target is the right home for a player.
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

    /// ⛔ THE RESOLVED URL LIVES HERE AND NOWHERE ELSE, for exactly as long as the
    /// sheet is up. It is a short-lived presigned object URL; storing it anywhere
    /// durable makes an expired link present as a corrupt recording. See the ⛔ on
    /// ``CallDetailModel/resolveRecording()``.
    @State private var playback: RecordingPlayback?

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
            .sheet(item: $playback) { RecordingPlayerSheet(url: $0.url) }
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
            CallDetailContentView(
                call: call,
                model: model,
                onPlay: playRecording
            )
        case let .failed(failure):
            FailureView(failure: failure, onRetry: reload)
        }
    }

    private func reload() {
        Task { await model.load() }
    }

    private func playRecording() {
        Task {
            guard let url = await model.resolveRecording() else { return }
            playback = RecordingPlayback(url: url)
        }
    }
}

/// The loaded call.
private struct CallDetailContentView: View {
    let call: CallSummary
    let model: CallDetailModel
    let onPlay: () -> Void

    @Environment(\.colorScheme) private var colorScheme

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
                recordingSection
            }
            .padding(DistrictSpacing.gutter)
            .districtReadableWidth()
        }
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
    /// where an operator decides whether to go listen to the recording. The wording
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

    @ViewBuilder
    private var transcriptSection: some View {
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

    // MARK: - Recording

    @ViewBuilder
    private var recordingSection: some View {
        switch model.recording {
        case .idle:
            // ⚠️ Offered from the row's `recordingUrl`, which is a hint rather than
            // the truth: an archived copy lives under a key this shape does not
            // expose, so the server can still produce a URL when it is absent.
            if model.mayHaveRecording {
                Button("Play recording", action: onPlay)
                    .buttonStyle(.districtPrimary)
            }
        case .resolving:
            ProgressView()
        case .absent:
            note("No recording for this call.")
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

/// The identity a `sheet(item:)` needs, wrapping one resolved URL.
///
/// ⚠️ A FRESH `id` PER RESOLUTION, so presenting the sheet twice for the same call
/// builds a new player rather than reusing a finished one.
private struct RecordingPlayback: Identifiable {
    let id = UUID()
    let url: URL
}

/// Playback, for as long as the sheet is up.
///
/// ⛔ NO DOWNLOAD, NO SHARE, NO WRITE TO DISK. The URL is a short-lived presigned
/// object URL for a customer's call recording; the only thing this app does with one
/// is hand it to a player and forget it.
private struct RecordingPlayerSheet: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer

    /// ⚠️ THE PLAYER IS BUILT ONCE, IN `init`. Constructing it in `body` would build a
    /// new one on every redraw and restart the audio.
    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VStack(spacing: DistrictSpacing.row) {
            VideoPlayer(player: player)
                .frame(height: 220)
            Button("Done") {
                player.pause()
                dismiss()
            }
            .buttonStyle(.districtSecondary)
        }
        .padding(DistrictSpacing.gutter)
        .onAppear { player.play() }
        .onDisappear { player.pause() }
    }
}
