/// The part of a live call that looks the same in both directions: how long it
/// has been running, what the microphone is doing, where the audio is going.
///
/// ⛔ IT EXISTS ONLY ONCE MEDIA IS UP. ``IncomingCallController`` holds it as an
/// optional and leaves it nil while the phone is ringing, which is what stops a
/// ringing screen drawing a duration. The outbound machine holds one from the
/// start because its own phase already says whether a timer should be running.
public struct CallMediaState: Sendable, Equatable {
    /// ⛔ COUNTED FROM THE ANSWER, NEVER FROM THE DIAL OR FROM THE PRESS, and the
    /// operator will compare it to an invoice. The platform bills answered time:
    /// counting from the dial would overstate every outbound call by its ring
    /// duration, and counting an inbound call from the Answer press would include
    /// the answer round trip and the join. Both make the app the thing that looks
    /// wrong.
    public internal(set) var elapsedSeconds: Int = 0

    /// ⚠️ TRUE FROM THE START, unlike a meeting. A softphone that joined muted
    /// would put the operator on a call the callee cannot hear, having just
    /// chosen to make it, and unlike a meeting there is no room full of people to
    /// notice.
    ///
    /// ⛔ WRITTEN ONLY BY ``CallEngineEvent/microphoneChanged(enabled:)``, never
    /// by the mute command. See that case.
    public internal(set) var microphoneEnabled: Bool = true

    /// What this app ASKED the audio route to be.
    ///
    /// ⚠️ AN INTENT, NOT A READOUT, and it is honest only as a toggle's own
    /// state. What the device is actually doing is ``audioRoute``.
    public internal(set) var speakerRequested: Bool = false

    /// What the device REPORTED, or nil before it has said anything.
    ///
    /// ⚠️ nil IS "NOT YET TOLD", NOT ``AudioRoute/earpiece``. Rendering a
    /// default here would state a fact about hardware nobody has asked.
    public internal(set) var audioRoute: AudioRoute?

    /// ⚠️ A BANNER, NEVER A PHASE. See ``CallEngineEvent/reconnecting``.
    public internal(set) var reconnecting: Bool = false

    /// How many participants other than this device are in the room.
    ///
    /// ⛔ A COUNT RATHER THAN A LIST, BECAUSE THE ONLY QUESTION EITHER MACHINE
    /// ASKS IS WHETHER IT IS ZERO. The Kotlin client holds the list because its
    /// meeting grid renders it; a CALL renders no roster, and keeping identities
    /// here would put a participant's name in a state object two screens are free
    /// to log.
    public internal(set) var remoteParticipants: Int = 0

    public init() {}
}

extension CallMediaState {
    /// Fold one engine event into the media state.
    ///
    /// ⛔ THE TERMINAL EVENTS ARE NOT HANDLED HERE, DELIBERATELY.
    /// ``CallEngineEvent/disconnected(reason:)`` and
    /// ``CallEngineEvent/failed(message:)`` end the call, which is a decision
    /// about the PHASE and belongs to whichever machine owns it — the two
    /// machines end for different reasons and emit different commands. Reaching
    /// them here would mean a media helper could silently end a call.
    mutating func apply(_ event: CallEngineEvent) {
        switch event {
        case .connected:
            // ⚠️ ALSO THE RECOVERY SIGNAL, which is why this clears the banner
            // rather than only being read on the first connect.
            reconnecting = false
        case .reconnecting:
            reconnecting = true
        case .participantJoined:
            remoteParticipants += 1
        case .participantLeft:
            // ⚠️ FLOORED AT ZERO. The SDK can report a leave for a participant
            // this client never saw join (a join that arrived while the stream
            // was being set up), and a negative count would make
            // "is the room empty" answer false for ever.
            remoteParticipants = max(0, remoteParticipants - 1)
        case let .audioRouteChanged(route):
            audioRoute = route
        case let .microphoneChanged(enabled):
            microphoneEnabled = enabled
        case .disconnected, .failed:
            break
        }
    }

    /// The command a mute toggle sends, with no change to this state.
    ///
    /// ⛔ THE FLAG IS NOT FLIPPED HERE. `microphoneEnabled` mirrors what the
    /// engine reports, so a mute the SDK refuses leaves the state saying the
    /// microphone is live, which is the truth. See
    /// ``CallEngineEvent/microphoneChanged(enabled:)``.
    ///
    /// ⚠️ Note the polarity: muting is what happens when the microphone is
    /// currently enabled.
    func muteToggleCommand() -> CallCommand {
        .setMuted(microphoneEnabled)
    }

    /// Flip the speaker request and return the command that carries it.
    ///
    /// ⚠️ SET SYNCHRONOUSLY, unlike the microphone, because there is nothing to
    /// mirror: this records what the app asked for. ``audioRoute`` is where the
    /// device's own answer lands, if and when it arrives.
    mutating func toggleSpeaker() -> CallCommand {
        speakerRequested.toggle()
        return .setSpeakerphone(speakerRequested)
    }
}
