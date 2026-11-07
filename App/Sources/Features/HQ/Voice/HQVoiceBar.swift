import DistrictModel
import SwiftUI

/// District HQ by voice, above the text console's composer: Talk, the region notice, the
/// session's state, its transcript, HQ's proposals and the microphone.
///
/// ⚠️ THE TEXT CONSOLE STAYS USABLE IN EVERY STATE, a refused or failed session included.
///
/// ⚠️ VOICEOVER: the agent's state is the state element's VALUE, so a change is read once
/// rather than announced on every turn; the transcript is final segments only, and the
/// member's own lines are told apart by a spoken "You".
struct HQVoiceBar: View {
    let session: HQVoiceSession
    /// The console's turns, for the agent to know the conversation so far.
    let history: () -> [HQVoiceTurn]
    let openSettings: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.workspaceRegion) private var workspaceRegion

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            switch session.phase {
            case .idle:
                idle(note: HQCopy.voiceMicExplainer, isFailure: false)
            case let .ended(reason):
                idle(note: Self.sentence(reason), isFailure: Self.isFailure(reason))
            case .minting, .notice, .connecting:
                HStack(spacing: DistrictSpacing.tight) {
                    ProgressView()
                    Text(HQCopy.voiceConnecting)
                        .font(DistrictType.caption)
                        .foregroundStyle(colors.mutedForeground)
                }
            case .live:
                live
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.HQVoice.bar)
        .sheet(isPresented: noticeShown) {
            if case let .notice(credential) = session.phase {
                HQVoiceNotice(
                    session: session,
                    regionLine: HQVoiceNotice.regionLine(
                        processing: credential.processingRegion,
                        workspace: workspaceRegion
                    )
                )
            }
        }
    }

    /// ⚠️ DISMISSED BY A SWIPE IS CANCEL: the session is discarded, nothing was joined.
    private var noticeShown: Binding<Bool> {
        Binding(
            get: {
                if case .notice = session.phase {
                    true
                } else {
                    false
                }
            },
            set: { shown in
                if !shown {
                    Task { await session.cancelNotice() }
                }
            }
        )
    }

    // MARK: - Not in a session

    private func idle(note: String, isFailure: Bool) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            HStack(spacing: DistrictSpacing.tight) {
                Button {
                    Task { await session.start(history: history(), locale: Self.locale) }
                } label: {
                    Label(HQCopy.voiceStart, systemImage: "mic")
                }
                .buttonStyle(.districtSecondary)
                .accessibilityIdentifier(A11yID.HQVoice.start)
                Spacer(minLength: 0)
                Button(action: openSettings) {
                    Image(systemName: "slider.horizontal.3")
                        .accessibilityLabel(HQCopy.voiceSettings)
                }
                .buttonStyle(.districtGhost)
                .accessibilityIdentifier(A11yID.HQVoice.settings)
            }
            Text(note)
                .font(DistrictType.caption)
                .foregroundStyle(isFailure ? colors.destructive : colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(A11yID.HQVoice.ended)
        }
    }

    // MARK: - In a session

    private var live: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            HStack(spacing: DistrictSpacing.tight) {
                Image(systemName: "waveform")
                    .foregroundStyle(colors.district)
                    .accessibilityHidden(true)
                Text(stateText)
                    .font(DistrictType.titleSmall)
                    .foregroundStyle(colors.foreground)
                    .accessibilityLabel(HQCopy.title)
                    .accessibilityValue(stateText)
                    .accessibilityIdentifier(A11yID.HQVoice.state)
                Spacer(minLength: 0)
                microphone
                Button(HQCopy.voiceStop) { Task { await session.stop() } }
                    .buttonStyle(.districtGhost)
                    .accessibilityIdentifier(A11yID.HQVoice.stop)
            }
            transcript
            ForEach(session.proposals) { card in
                HQVoiceProposalCard(session: session, card: card)
            }
        }
    }

    private var stateText: String {
        switch session.agentState {
        case .thinking: HQCopy.voiceThinking
        case .speaking: HQCopy.voiceSpeaking
        case .listening, nil: HQCopy.voiceListening
        }
    }

    /// ⛔ PUSH-TO-TALK IS OPEN ONLY WHILE HELD; VoiceOver's double tap toggles it instead.
    @ViewBuilder
    private var microphone: some View {
        switch session.micMode {
        case .push:
            Label(HQCopy.voiceHoldToTalk, systemImage: session.isMicrophoneOn ? "mic.fill" : "mic.slash")
                .font(DistrictType.caption)
                .padding(.vertical, DistrictSpacing.tight)
                .padding(.horizontal, DistrictSpacing.row)
                .background(
                    session.isMicrophoneOn ? colors.district.opacity(DistrictColors.containerAlpha) : colors.muted,
                    in: Capsule()
                )
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !session.isMicrophoneOn {
                                Task { await session.holdToTalk(true) }
                            }
                        }
                        .onEnded { _ in Task { await session.holdToTalk(false) } }
                )
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAddTraits(session.isMicrophoneOn ? .isSelected : [])
                .accessibilityAction { Task { await session.holdToTalk(!session.isMicrophoneOn) } }
                .accessibilityIdentifier(A11yID.HQVoice.holdToTalk)
        case .open:
            Button {
                Task { await session.toggleMute() }
            } label: {
                Image(systemName: session.isMicrophoneOn ? "mic.fill" : "mic.slash")
                    .accessibilityLabel(session.isMicrophoneOn ? HQCopy.voiceMute : HQCopy.voiceUnmute)
            }
            .buttonStyle(.districtGhost)
            .accessibilityIdentifier(A11yID.HQVoice.mute)
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if !session.segments.isEmpty {
            VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                ForEach(session.segments.suffix(4)) { segment in
                    VStack(alignment: segment.fromMember ? .trailing : .leading, spacing: 0) {
                        Text(segment.fromMember ? HQCopy.voiceYou : HQCopy.title)
                            .font(DistrictType.labelSmall)
                            .foregroundStyle(colors.mutedForeground)
                        Text(segment.text)
                            .font(DistrictType.caption)
                            .foregroundStyle(colors.foreground)
                            .multilineTextAlignment(segment.fromMember ? .trailing : .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: segment.fromMember ? .trailing : .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(A11yID.HQVoice.transcript)
        }
    }

    // MARK: - Words

    static var locale: String {
        AppL10n.copyLocale == .frCA ? "fr" : "en"
    }

    static func sentence(_ reason: HQVoiceSession.EndReason) -> String {
        switch reason {
        case .byMember, .disconnected: HQCopy.voiceEnded
        case .callArrived: HQCopy.voiceEndedCall
        case .timedOut: HQCopy.voiceEndedTimeout
        case .busy: HQCopy.voiceBusy
        case .microphoneDenied: HQCopy.voiceMicDenied
        case let .refused(message), let .failed(message): message
        }
    }

    static func isFailure(_ reason: HQVoiceSession.EndReason) -> Bool {
        switch reason {
        case .byMember, .disconnected, .callArrived, .timedOut: false
        case .busy, .microphoneDenied, .refused, .failed: true
        }
    }
}

/// The region notice: where the voice is processed, before the microphone opens.
///
/// ⛔ THE REGION IS THE SERVICE'S `processingRegion`, never a list kept here: the line above
/// the disclosure appears only when it is not the workspace's own region.
struct HQVoiceNotice: View {
    let session: HQVoiceSession
    let regionLine: String?

    /// The line above the disclosure, or nil when voice is processed in the workspace's region
    /// (or the workspace's region is not known).
    static func regionLine(processing: String, workspace: String?) -> String? {
        guard let workspace, workspace != processing else { return nil }
        return HQCopy.voiceNoticeRegion(RegionCopy.label(workspace))
    }

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        // ⚠️ THE TEXT SCROLLS AND THE TWO BUTTONS STAY BELOW IT, so a large text size never
        // pushes Start and Cancel off the sheet.
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            ScrollView {
                VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                    Text(HQCopy.voiceNoticeTitle)
                        .font(DistrictType.title)
                        .foregroundStyle(colors.foreground)
                        .accessibilityAddTraits(.isHeader)
                    if let regionLine {
                        Text(regionLine)
                            .font(DistrictType.titleSmall)
                            .foregroundStyle(colors.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(HQCopy.voiceNoticeBody)
                        .font(DistrictType.bodySmall)
                        .foregroundStyle(colors.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: DistrictSpacing.row) {
                Button(HQCopy.voiceNoticeStart) { Task { await session.begin() } }
                    .buttonStyle(.districtPrimary)
                    .accessibilityIdentifier(A11yID.HQVoice.noticeStart)
                Button(HQCopy.voiceNoticeCancel) { Task { await session.cancelNotice() } }
                    .buttonStyle(.districtGhost)
                    .accessibilityIdentifier(A11yID.HQVoice.noticeCancel)
            }
        }
        .padding(DistrictSpacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.background)
        .presentationDetents([.medium, .large])
        // ⚠️ `.contain` FIRST: an identifier on a plain stack replaces its buttons' own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.HQVoice.notice)
    }
}

/// One change HQ proposed by voice. ⛔ The summary is the subject, never the tool name; the
/// member confirms by voice, or with Confirm here.
private struct HQVoiceProposalCard: View {
    let session: HQVoiceSession
    let card: HQVoiceSession.ProposalCard

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
            Text(card.proposal.summary.isEmpty ? HQCopy.voiceProposalFallback : card.proposal.summary)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
                .fixedSize(horizontal: false, vertical: true)
            if let outcome = card.outcome {
                Text(Self.sentence(outcome))
                    .font(DistrictType.caption)
                    .foregroundStyle(outcome == .failed ? colors.destructive : colors.mutedForeground)
            } else {
                controls
            }
        }
        .padding(DistrictSpacing.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .districtCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.HQVoice.proposal(card.id))
    }

    private var controls: some View {
        HStack(spacing: DistrictSpacing.row) {
            if session.canConfirm {
                Button(HQCopy.voiceConfirm) { Task { await session.confirm(card) } }
                    .buttonStyle(.districtPrimary)
                    .disabled(card.isWorking)
                    .accessibilityIdentifier(A11yID.HQVoice.confirm(card.id))
            }
            Button(HQCopy.voiceCancel) { Task { await session.cancel(card) } }
                .buttonStyle(.districtGhost)
                .disabled(card.isWorking)
                .accessibilityIdentifier(A11yID.HQVoice.cancel(card.id))
        }
    }

    static func sentence(_ outcome: HQResolutionStatus) -> String {
        switch outcome {
        case .applied: HQCopy.voiceApplied
        case .failed: HQCopy.voiceFailed
        case .cancelled: HQCopy.voiceCancelled
        }
    }
}

extension EnvironmentValues {
    /// The selected workspace's region (`us`, `ca`, `eu`, `apac`), for the HQ voice notice.
    /// Set by ``ShellView``; nil outside the signed-in shell.
    @Entry var workspaceRegion: String?
}
