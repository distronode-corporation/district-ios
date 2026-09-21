import DistrictCall
import SwiftUI

/// One inbound call, from the ring to the hang-up.
///
/// ⛔ THE CONNECTED HALF IS ``InCallView``, REUSED RATHER THAN REBUILT. Mute,
/// speaker, hang up, the duration, the reconnecting banner and the ended summary
/// are identical for an inbound and an outbound call — they are properties of a
/// live audio call, not of how it started — and a second copy would be the thing
/// that drifts. What is genuinely different is the RING, which outbound does not
/// have, and that is the only part drawn here. The Kotlin `IncomingCallScreen`
/// makes exactly this split.
///
/// ⛔ THE PHASE GATES THE HAND-OVER, NOT THE PRESENCE OF MEDIA, AND THE DIFFERENCE
/// IS VISIBLE. ``IncomingCallPhase/answering`` is a phase of its own rather than a
/// spinner over the ring, because the two accept different input: Answer and
/// Decline are both live while ringing, and once the answer round trip is out
/// neither may be pressed again. Branching on `media != nil` instead would draw
/// the in-call surface with a live Hang up button over a call that has not been
/// joined, and skip the connecting state entirely.
///
/// ⛔ THE BUTTONS ARE CHOSEN BY PHASE, NOT DISABLED BY IT. A disabled Answer on a
/// call that is already connecting is a control that looks momentarily broken; an
/// absent one is a state change the user can read. And a decline landing mid-join
/// would tear down a call whose credential has already been spent and whose
/// rendezvous the server has already read.
///
/// ⚠️ A FULL-SCREEN COVER RATHER THAN A NAVIGATION DESTINATION, for the reason
/// ``DialerModel`` holds its call in state: a destination restored from a back
/// stack after process death re-runs whatever effect put it there, and here that
/// would be a ringing screen for a call that died with the process.
struct IncomingCallView: View {
    let model: IncomingCallModel

    /// ⚠️ SUPPLIED BY THE SHELL, WHICH IS THE ONLY THING THAT HAS LOADED THE
    /// WORKSPACE LIST. nil is ordinary rather than exceptional: a cold launch from
    /// a VoIP push has not read it yet.
    let workspaceName: String?

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    /// ⚠️ IT CHANGES MID-RING AND THAT IS THE POINT. ``IncomingCallModel/caller``
    /// is nil when the screen first draws and is filled in when the identity
    /// lookup answers, so this reads as "Incoming call · Acme" and then as
    /// "Jane Doe · Acme" a moment later. The dependency is an `@Observable` stored
    /// property, so the redraw needs nothing here. ⚠️ It also feeds ``InCallView``
    /// as the title, which is why the caller survives the answer.
    private var callerLine: String {
        IncomingCallCopy.callerLine(caller: model.caller?.displayLine, workspaceName: workspaceName)
    }

    var body: some View {
        ZStack {
            colors.background.ignoresSafeArea()
            content
        }
    }

    /// ⚠️ THE ENDED PHASE STAYS ON THE IN-CALL SURFACE WHEN THE CALL WAS ANSWERED,
    /// because that is where the final duration and the call-log notice live. An
    /// ended call that never connected has neither, so it keeps the ringing surface
    /// and shows the reason instead.
    @ViewBuilder
    private var content: some View {
        if model.state.media != nil {
            InCallView(
                display: .inbound(model.state, title: callerLine, endedByOperator: model.endedByOperator),
                controls: model
            )
        } else {
            ringing
        }
    }

    private var ringing: some View {
        VStack(spacing: DistrictSpacing.row) {
            Spacer(minLength: 0)
            Text(callerLine)
                .font(DistrictType.headline)
                .foregroundStyle(colors.foreground)
                .multilineTextAlignment(.center)
            Text(IncomingCallCopy.sentence(for: model.state, endedByOperator: model.endedByOperator))
                .font(DistrictType.title)
                .foregroundStyle(colors.mutedForeground)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
            actions
        }
        .padding(DistrictSpacing.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var actions: some View {
        switch model.state.phase {
        case .idle, .ringing:
            ringingActions
        // ⛔ NOTHING TO PRESS WHILE THE ANSWER ROUND TRIP IS OUT. See the ⛔ on the
        // type.
        case .answering:
            EmptyView()
        case .ended:
            Button("Done") { model.dismissEndedCall() }
                .buttonStyle(.districtPrimary)
        // ⚠️ UNREACHABLE: `inCall` always carries media, which the branch above
        // hands to ``InCallView`` before this is evaluated.
        case .inCall:
            EmptyView()
        }
    }

    private var ringingActions: some View {
        VStack(spacing: DistrictSpacing.tight) {
            Text(IncomingCallCopy.answerNotice)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .multilineTextAlignment(.center)
            Button("Answer") { model.answerPressed() }
                .buttonStyle(.districtPrimary)
            // ⛔ DECLINING SENDS NOTHING TO THE SERVER. See the ⛔ on
            // ``IncomingCallController``: a deliberate refusal and a phone in a
            // pocket must be indistinguishable from outside.
            Button("Decline") { model.declinePressed() }
                .buttonStyle(.districtDestructive)
        }
    }
}
