import DistrictNetwork
import SwiftUI

/// The persona audition, as a sheet over the form it is auditioning.
///
/// ⛔ A SHEET RATHER THAN A DESTINATION, AND THAT IS A SAFETY DECISION RATHER THAN A
/// NAVIGATION ONE. A pushed route is restored from the back stack after process death,
/// which for this screen would mean a killed phone coming back and minting a fresh
/// billed session nobody asked for. ``Route/dialer`` refuses to have an in-call route
/// for the same reason. A sheet is dismissed by the system and never restored.
///
/// ⛔ NOTHING STARTS ON APPEAR. The session begins on a press and ends on every exit —
/// including the one nobody pressed, which is what `onDisappear` is for: a dismissed
/// sheet must not leave a room publishing a microphone.
///
/// ⚠️ IT DRAWS WHAT IS TRUE AND NEVER WHAT WAS ASKED FOR. The state line follows the
/// engine's own events, so "the agent is listening" appears when the agent is actually
/// in the room rather than when the connect returned.
struct PersonaPreviewView: View {
    @State private var model: PersonaPreviewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String, form: PersonaPreviewForm) {
        _model = State(initialValue: PersonaPreviewModel(
            container: container,
            workspaceId: workspaceId,
            form: form
        ))
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                    SettingsCard(eyebrow: SettingsCopy.previewTitle) {
                        intro
                        status
                        meter
                        notices
                        controls
                    }
                }
                .padding(DistrictSpacing.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier(A11yID.PersonaPreview.root)
            .navigationTitle(SettingsCopy.previewTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onDisappear {
            // ⛔ THE ONE TEARDOWN THAT COVERS THE EXIT NOBODY CHOSE. A swipe-down, a
            // sign-out and a workspace switch all destroy this view without pressing
            // anything; the model is held by ``CallStack`` for as long as the session
            // lives, so the Task outlives the view and the room is left properly.
            Task { await model.end() }
        }
    }

    private var intro: some View {
        Text(SettingsCopy.previewIntro)
            .font(DistrictType.bodySmall)
            .foregroundStyle(colors.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// ⚠️ ONE LINE THAT ALWAYS SAYS SOMETHING. A screen whose only feedback is a
    /// spinner cannot tell "connecting" from "connected, and the agent has not arrived".
    private var status: some View {
        Text(statusText)
            .font(DistrictType.title)
            .foregroundStyle(colors.foreground)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(A11yID.PersonaPreview.status)
    }

    private var statusText: String {
        switch model.phase {
        case .idle: SettingsCopy.previewIntro
        case .minting, .connecting: SettingsCopy.previewConnecting
        case .waiting: SettingsCopy.previewWaiting
        case .live: SettingsCopy.previewLive
        case .reconnecting: SettingsCopy.previewReconnecting
        case let .ended(ending): Self.endingText(ending)
        case .failed: model.failure?.message ?? SettingsCopy.previewDropped
        }
    }

    /// ⛔ THE THREE ENDINGS READ DIFFERENTLY BECAUSE THEY ARE DIFFERENT. Telling somebody
    /// they stopped a session that a call took from them, on a screen whose next button
    /// spends money, is how a second one gets started.
    private static func endingText(_ ending: PersonaPreviewEnding) -> String {
        switch ending {
        case .stopped:
            SettingsCopy.previewEnded
        case let .droppedRemotely(reason):
            reason.map { "\(SettingsCopy.previewDropped) \($0)" } ?? SettingsCopy.previewDropped
        case let .yielded(reason):
            switch reason {
            case .telephoneCall: SettingsCopy.previewYieldedToCall
            case .sessionEnded, .workspaceChanged: SettingsCopy.previewEnded
            }
        }
    }

    /// ⚠️ A BAR AND A SENTENCE, NOT A BAR. A level drawn only as a filled rectangle is
    /// invisible to VoiceOver, and "is it actually saying anything" is the question this
    /// screen exists to answer.
    @ViewBuilder
    private var meter: some View {
        if model.phase.isRunning {
            VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                Text(SettingsCopy.previewLevelLabel)
                    .font(DistrictType.labelSmall)
                    .foregroundStyle(colors.mutedForeground)
                ProgressView(value: min(max(model.level, 0), 1))
                    .tint(colors.district)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(SettingsCopy.previewLevelLabel)
            .accessibilityValue(SettingsCopy.previewLevelValue(model.level))
            .accessibilityIdentifier(A11yID.PersonaPreview.level)
        }
    }

    @ViewBuilder
    private var notices: some View {
        if model.microphoneDenied {
            notice(SettingsCopy.previewMicrophoneDenied, colors.warning)
        }
        if let refusal = model.refusal, !model.phase.isRunning {
            notice(refusal, colors.mutedForeground)
        }
    }

    private func notice(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(DistrictType.caption)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// ⛔ ONE CONTROL AT A TIME. A Start beside an End on a screen where one of them
    /// costs money is an invitation to press the wrong one.
    @ViewBuilder
    private var controls: some View {
        if model.phase.isRunning {
            Button(SettingsCopy.previewEnd) { Task { await model.end() } }
                .buttonStyle(.districtDestructive)
                .accessibilityIdentifier(A11yID.PersonaPreview.end)
        } else {
            Button(SettingsCopy.previewStart) { Task { await model.start() } }
                .buttonStyle(.districtPrimary)
                .disabled(!model.canStart)
                .accessibilityIdentifier(A11yID.PersonaPreview.start)
        }
    }
}
