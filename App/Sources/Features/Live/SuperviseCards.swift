import DistrictCall
import SwiftUI

/// The call card: where the person is in the call, and the one or two things they may do.
///
/// ⚠️ EVERY CONTROL IS OFFERED FROM THE CORE'S PREDICATES (`mayListen`, `mayTakeOver`,
/// `holdsTheCall`), never from a phase compared here, so a viewer and a colleague's own call
/// get exactly what the reducer allows.
struct SuperviseCallCard: View {
    let model: SuperviseModel
    @Binding var confirmingTakeover: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private var state: SuperviseState {
        model.state
    }

    var body: some View {
        DistrictCard(spacing: DistrictSpacing.row) {
            status
            controls
            if let problem = model.startRefusal ?? SuperviseCopy.problem(state.problem) {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.destructive)
                    .accessibilityIdentifier(A11yID.Live.problem)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.Live.callCard)
    }

    @ViewBuilder
    private var status: some View {
        switch state.phase {
        case .idle where model.starting, .requestingListen, .joiningListen:
            progress(SuperviseCopy.joining)
        case .idle:
            text(SuperviseCopy.listenInHeading, SuperviseCopy.listenInBody)
        case .listening:
            text(SuperviseCopy.monitoringConnected, SuperviseCopy.listenInBody)
        case .requestingTakeover, .joiningTakeover:
            progress(SuperviseCopy.takingOver)
        case .takenOver:
            text(SuperviseCopy.takenOverHeading, SuperviseCopy.takenOverBody)
        case .over:
            Label(SuperviseCopy.callEnded, systemImage: "phone.down")
                .font(DistrictType.body)
                .foregroundStyle(colors.mutedForeground)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch state.phase {
        case .idle where !model.starting:
            Button(SuperviseCopy.monitorAudio, systemImage: "headphones") { model.listen() }
                .buttonStyle(DistrictButtonStyle(variant: .primary))
                .disabled(!model.mayListen)
                .accessibilityIdentifier(A11yID.Live.listen)
        case .idle, .requestingListen, .joiningListen:
            stopButton
        case .listening, .requestingTakeover:
            FlowLayout(spacing: DistrictSpacing.tight, lineSpacing: DistrictSpacing.tight) {
                speakerButton
                stopButton
            }
            if state.mayTakeOver || state.phase == .requestingTakeover {
                Button(SuperviseCopy.takeOver, systemImage: "person.wave.2") { confirmingTakeover = true }
                    .buttonStyle(DistrictButtonStyle(variant: .secondary))
                    .disabled(!state.mayTakeOver)
                    .accessibilityIdentifier(A11yID.Live.takeOver)
            }
        case .joiningTakeover:
            EmptyView()
        case .takenOver:
            FlowLayout(spacing: DistrictSpacing.tight, lineSpacing: DistrictSpacing.tight) {
                muteButton
                speakerButton
            }
            Button(SuperviseCopy.handBack, systemImage: "arrow.uturn.backward") { Task { await model.stop() } }
                .buttonStyle(DistrictButtonStyle(variant: .primary))
                .accessibilityIdentifier(A11yID.Live.handBack)
        case .over:
            EmptyView()
        }
    }

    private var stopButton: some View {
        Button(SuperviseCopy.disconnect, systemImage: "stop.circle") { Task { await model.stop() } }
            .buttonStyle(DistrictButtonStyle(variant: .secondary))
            .accessibilityIdentifier(A11yID.Live.stop)
    }

    private var speakerButton: some View {
        let on = state.media.speakerRequested
        return Button(
            on ? DialerCopy.speakerOn : DialerCopy.speakerOff,
            systemImage: on ? "speaker.wave.2.fill" : "speaker.wave.2"
        ) {
            Task { await model.toggleSpeaker() }
        }
        .buttonStyle(DistrictButtonStyle(variant: on ? .primary : .ghost))
    }

    private var muteButton: some View {
        let live = state.media.microphoneEnabled
        return Button(live ? DialerCopy.mute : DialerCopy.unmute, systemImage: live ? "mic" : "mic.slash") {
            model.toggleMute()
        }
        .buttonStyle(DistrictButtonStyle(variant: live ? .ghost : .primary))
        .accessibilityIdentifier(A11yID.Live.mute)
    }

    private func text(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(title)
                .font(DistrictType.title)
                .foregroundStyle(colors.foreground)
            Text(body)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
        }
        .accessibilityElement(children: .combine)
    }

    private func progress(_ line: String) -> some View {
        HStack(spacing: DistrictSpacing.tight) {
            ProgressView()
            Text(line)
                .font(DistrictType.body)
                .foregroundStyle(colors.foreground)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The note to the receptionist, and its receipt.
///
/// ⛔ A VIEWER SEES THE WEBSITE'S "Viewers cannot send notes" AND NO BOX, and a person holding
/// the call sees "Hand the call back…": a note then would make the receptionist speak over them.
struct SuperviseWhisperCard: View {
    @Bindable var model: SuperviseModel

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private var state: SuperviseState {
        model.state
    }

    var body: some View {
        if state.phase != .over {
            DistrictCard(eyebrow: SuperviseCopy.whisperHeading, spacing: DistrictSpacing.row) {
                if state.role?.canMutate != true {
                    muted(SuperviseCopy.whisperDisabledPlaceholder)
                } else if !state.mayWhisper {
                    muted(SuperviseCopy.whisperTakenOverPlaceholder)
                } else {
                    composer
                }
                if let receipt = state.receipt {
                    receiptView(SuperviseCopy.receipt(receipt), applied: receipt.applied)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(A11yID.Live.whisper)
        }
    }

    @ViewBuilder
    private var composer: some View {
        TextField(
            SuperviseCopy.whisperHeading,
            text: $model.draft,
            prompt: Text(SuperviseCopy.whisperPlaceholder),
            axis: .vertical
        )
        .lineLimit(2 ... 5)
        .disabled(model.sending)
        .districtField()
        .accessibilityIdentifier(A11yID.Live.whisperField)
        if let problem = model.whisperProblem {
            Text(problem)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.destructive)
        }
        Button(SuperviseCopy.whisperSend, systemImage: "paperplane") { Task { await model.sendWhisper() } }
            .buttonStyle(DistrictButtonStyle(variant: .primary))
            .disabled(model.sending || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier(A11yID.Live.whisperSend)
    }

    private func muted(_ line: String) -> some View {
        Text(line)
            .font(DistrictType.bodySmall)
            .foregroundStyle(colors.mutedForeground)
    }

    private func receiptView(_ receipt: (headline: String, detail: String?), applied: Bool) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Label(receipt.headline, systemImage: applied ? "checkmark.circle" : "exclamationmark.circle")
                .font(DistrictType.label)
                .foregroundStyle(applied ? colors.foreground : colors.mutedForeground)
            if let detail = receipt.detail {
                Text(detail)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.mutedForeground)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(A11yID.Live.receipt)
    }
}
