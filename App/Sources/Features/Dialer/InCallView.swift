import DistrictCall
import SwiftUI

/// One live call, while it is happening, in either direction.
///
/// ⚠️ IT SERVES BOTH DIRECTIONS, WHICH IS WHY IT TAKES A ``LiveCallDisplay`` AND A
/// ``LiveCallControls`` RATHER THAN A ``DialerModel``. Everything below is a
/// property of a live audio call and not of how it started; the RING is the part
/// that genuinely differs, and that is drawn by ``IncomingCallView`` and never
/// reaches here. The file lives under `Features/Dialer/`, beside the outbound call.
///
/// ⛔ NO VIDEO TILE AND NO CAMERA CONTROL EXIST HERE, AND NONE MAY BE ADDED. The
/// softphone publishes no video in either direction: ``CallCommand`` has no camera case
/// and ``CallEngine`` has no camera member, so a control here would have nothing to
/// call — and the token the dial route mints WOULD permit publishing. A camera track
/// pushed into a `direct_` room would be encoded, uploaded and billed with nobody able
/// to see it, because the far end is a telephone. The absence is the enforcement.
///
/// ⛔ "Calling…" AND THE TIMER ARE DIFFERENT PHASES AND NEVER BOTH. `POST
/// /api/district/calls/dial` returns as soon as the carrier accepts, so being in the
/// room is not being on a call; ``SoftphonePhase/ringing`` is its own phase and the
/// duration starts at ``SoftphonePhase/connected``, which is the participant join. A
/// duration shown during the ring would count ringing as conversation, on the number an
/// operator compares against an invoice.
///
/// ⛔ RECONNECTING IS A BANNER OVER THE CALL, NEVER A PHASE, which is why it is drawn
/// as a second line rather than replacing the first. A phone walking out of wifi onto
/// its radio does this routinely and the SDK recovers by itself; ``CallMediaState`` says
/// so on ``CallMediaState/reconnecting``.
///
/// ⚠️ THE ENDED STATE IS A SCREEN, NOT AN IMMEDIATE POP. The operator needs to see the
/// duration and be told the record is the call log; a surface that vanished on hang-up
/// would answer "how long was that" with nothing.
struct InCallView: View {
    let display: LiveCallDisplay

    /// ⚠️ THE MODEL, NOT A SNAPSHOT. See the ⚠️ on ``LiveCallControls``.
    let controls: any LiveCallControls

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    private var ended: Bool {
        display.ended
    }

    var body: some View {
        VStack(spacing: DistrictSpacing.row) {
            Spacer(minLength: 0)
            callee
            phaseLine
            reconnecting
            logNotice
            Spacer(minLength: 0)
            controlsSection
        }
        .padding(DistrictSpacing.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Who and what

    /// ⚠️ AS TYPED, ON AN OUTBOUND CALL. The server normalised its own copy; this is
    /// the string the operator will recognise, and it never travels. On an INBOUND
    /// call it is a label, because the ring push carries identifiers only — see
    /// ``LiveCallDisplay/title``.
    private var callee: some View {
        Text(display.title)
            .font(DistrictType.headline)
            .foregroundStyle(colors.foreground)
            .multilineTextAlignment(.center)
    }

    private var phaseLine: some View {
        Text(display.sentence)
            .font(DistrictType.title)
            .foregroundStyle(colors.mutedForeground)
            .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var reconnecting: some View {
        if display.media.reconnecting, !ended {
            Text("Reconnecting…")
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
        }
    }

    /// ⚠️ STATED, BECAUSE THIS APP NEVER WRITES THE CALL'S OUTCOME. The row's terminal
    /// status and its billed duration come from the carrier's webhooks, so the log is
    /// the record and this screen is not.
    @ViewBuilder
    private var logNotice: some View {
        if ended {
            Text(LiveCallDisplay.logNotice)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Controls

    /// ⛔ NOT `controls`. The injected ``LiveCallControls`` at the top of this type is
    /// called `controls`, and a view of the same name shadowed it: `controls.hangUp()`
    /// inside this very property was reaching for the protocol while `body` was reaching
    /// for the view, which Swift 6 rejects outright as a redeclaration rather than
    /// resolving one of them quietly. The section keeps the `-Section` suffix so the
    /// next extraction cannot recreate the collision by accident.
    @ViewBuilder
    private var controlsSection: some View {
        if ended {
            Button("Done") { controls.dismissEndedCall() }
                .buttonStyle(.districtPrimary)
        } else {
            liveControls
        }
    }

    /// Mute, speaker, hang up.
    ///
    /// ⚠️ THREE CONTROLS, AND THE ABSENT FOURTH IS THE POINT. See the ⛔ on the type.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var liveControls: some View {
        // ⛔ THE TWO SECONDARY CONTROLS STACK AT AN ACCESSIBILITY SIZE. "Speaker off"
        // beside "Unmute" at AX5 is two buttons sharing a phone's width, so both
        // labels truncate to a syllable — on the one screen where a mis-tap ends a
        // live call. `AnyLayout` swaps the arrangement without rebuilding the buttons.
        let row = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: DistrictSpacing.tight))
            : AnyLayout(HStackLayout(spacing: DistrictSpacing.tight))
        return VStack(spacing: DistrictSpacing.tight) {
            row {
                // ⛔ THE LABEL IS THE ACTION, NOT THE STATE. `microphoneEnabled` mirrors
                // what the SDK reported, so a mute it refused leaves this saying "Mute",
                // which is the truth.
                Button(display.media.microphoneEnabled ? "Mute" : "Unmute") { controls.toggleMute() }
                    .buttonStyle(.districtSecondary)
                // ⚠️ THE ASK, NOT THE DEVICE'S ANSWER. ``CallMediaState/audioRoute`` is
                // where the device's own report lands, and the two disagree whenever
                // something with a stronger claim (a headset, a car) is attached.
                // ⛔ ABSENT WHERE THERE IS NO EARPIECE TO SWITCH AWAY FROM, where "Speaker
                // off" would be false. See ``SpeakerToggleRule``.
                if AudioOutputs.shared.offersSpeakerToggle(speakerRequested: display.media.speakerRequested) {
                    Button(display.media.speakerRequested ? "Speaker on" : "Speaker off") {
                        Task { await controls.toggleSpeaker() }
                    }
                    .buttonStyle(.districtSecondary)
                }
            }
            // ⛔ THROUGH CALLKIT, SO THE OS AND THIS SCREEN AGREE. See
            // ``DialerModel/hangUp()``.
            Button("Hang up") { Task { await controls.hangUp() } }
                .buttonStyle(.districtDestructive)
        }
    }
}

/// The one line that says what is happening.
///
/// ⛔ DERIVED FROM THE PHASE IN ONE PLACE SO THE LABEL AND THE TIMER CANNOT DISAGREE.
/// The Kotlin client had to compute its phase centrally for the same reason: two of its
/// states looked identical in the connection state alone. Here the reducer already owns
/// the phase, so this is only the wording.
enum InCallCopy {
    static func sentence(for state: SoftphoneState, endedByOperator: Bool) -> String {
        switch state.phase {
        // ⚠️ ONE SENTENCE FOR BOTH, because the difference between "the request is out"
        // and "the room is being joined" is not a difference an operator can act on.
        case .idle, .dialing, .connecting:
            "Calling…"
        // ⛔ IN THE ROOM, NOBODY ON THE LINE YET. See the ⛔ on ``SoftphonePhase/ringing``.
        case .ringing:
            "Ringing…"
        case .connected:
            "Connected · \(duration(state.media.elapsedSeconds))"
        case let .ended(reason):
            endedSentence(
                word: word(for: reason, endedByOperator: endedByOperator),
                seconds: state.media.elapsedSeconds,
                answered: state.answered
            )
        }
    }

    /// ⚠️ THE DURATION IS APPENDED ONLY WHEN THE CALL WAS ANSWERED. ``SoftphoneState``
    /// latches `answered` for exactly this: a zero on an unanswered call is what tells
    /// the operator the callee never picked up, and "Lasted 0:00" says the opposite.
    ///
    /// ⛔ `endedByOperator` IS NOT OPTIONAL AND HAS NO DEFAULT, DELIBERATELY. This
    /// overload is what the INBOUND screen calls: a default of `false` would be safe
    /// and a default of `true` would reinstate the mislabel described on
    /// ``word(for:endedByOperator:)``, so neither is written and every caller has to
    /// say which it knows.
    static func endedSentence(
        reason: CallEndReason,
        endedByOperator: Bool,
        seconds: Int,
        answered: Bool
    ) -> String {
        endedSentence(
            word: word(for: reason, endedByOperator: endedByOperator),
            seconds: seconds,
            answered: answered
        )
    }

    /// ⚠️ A nil WORD IS "WE DO NOT KNOW WHO ENDED IT" AND THE SENTENCE SHORTENS RATHER
    /// THAN GUESSING. "Call ended · 1:02" says everything that is known; the head is
    /// never left dangling on a separator.
    static func endedSentence(word: String?, seconds: Int, answered: Bool) -> String {
        let head = word.map { "Call ended · \($0)" } ?? "Call ended"
        guard answered else { return head }
        return "\(head) · \(duration(seconds))"
    }

    /// ⚠️ mm:ss, AND IT KEEPS COUNTING PAST AN HOUR RATHER THAN WRAPPING. A 72-minute
    /// call reads "72:14", which is long but never wrong; an hours field would read
    /// "12:14" for the same call unless it also carried the hour.
    ///
    /// ⚠️ INTERPOLATED RATHER THAN `String(format:)`. `%d` is a C `int` and an `Int` is
    /// 64-bit here; the pairing happens to work little-endian, which is exactly the kind
    /// of thing that is fine until it is not, and it would cost a Foundation import for
    /// two divisions.
    static func duration(_ seconds: Int) -> String {
        let safe = max(0, seconds)
        let remainder = safe % 60
        let padded = remainder < 10 ? "0\(remainder)" : "\(remainder)"
        return "\(safe / 60):\(padded)"
    }

    /// The outbound word, which is not always the shared one.
    ///
    /// ⛔ "you hung up" IS A CLAIM ABOUT A PERSON AND THE REDUCER CANNOT MAKE IT.
    /// ``SoftphoneEvent/hangUpPressed`` is fed by ``DialerModel/hangUp()`` AND by a
    /// `CXEndCallAction` the OS performed, and ``CallEndReason/hungUpLocally`` says so
    /// in its own doc: "the button, or the OS's own end-call affordance". The system
    /// affordance is USUALLY the operator, but it is also the lock-screen banner, a
    /// headset button, a car head unit and iOS itself, so the app does not know.
    ///
    /// ⛔ MEASURED, NOT HYPOTHETICAL: a `CXEndCallAction` can land 1.1s after the start
    /// action, during the dial's round trip, where "you hung up" would tell an
    /// operator they ended a call they did not. Saying only "Call ended" there claims
    /// nothing the app does not know.
    ///
    /// ⚠️ EVERY OTHER REASON IS UNAFFECTED, including the inbound ones: this is the
    /// one case where two causes share a reason.
    static func word(for reason: CallEndReason, endedByOperator: Bool) -> String? {
        guard case .hungUpLocally = reason else { return word(for: reason) }
        return endedByOperator ? word(for: reason) : nil
    }

    /// ⛔ EVERY CASE IS ANSWERED EVEN THOUGH FOUR OF THEM BELONG TO THE INBOUND MACHINE.
    /// ``CallEndReason`` is one vocabulary for both directions on purpose, so this switch
    /// is exhaustive rather than defaulted: a new reason has to be worded here before it
    /// compiles, which is the whole value of not writing `default`.
    ///
    /// ⛔ PRIVATE, AND THAT IS LOAD-BEARING RATHER THAN A TIDY-UP. This overload names
    /// a person for `hungUpLocally` without being told whether a person did it, so the
    /// only safe caller is ``word(for:endedByOperator:)`` directly above, which asks
    /// that question first. An `internal` one would be reachable from any screen's
    /// copy, `IncomingCallCopy` included, and each would say "you hung up" for an end
    /// it could not attribute.
    private static func word(for reason: CallEndReason) -> String {
        switch reason {
        case .hungUpLocally: "you hung up"
        case .remoteHungUp: "they hung up"
        case let .remoteEnded(text): text ?? "the other end ended it"
        case let .failed(message): message ?? "the call could not be connected"
        case .declined: "declined"
        case .ringTimedOut: "nobody answered"
        case .callerCancelled: "the caller hung up"
        case let .answerRefused(message): message ?? "the answer was refused"
        }
    }
}
