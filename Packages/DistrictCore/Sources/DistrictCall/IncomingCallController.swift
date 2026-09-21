/// Where the app is in an INBOUND call.
///
/// ⛔ ``answering`` IS A PHASE OF ITS OWN AND NOT A SPINNER OVER ``ringing``,
/// BECAUSE THE TWO ACCEPT DIFFERENT INPUT. Answer and Decline are both live while
/// ringing; once the answer round trip is out neither may be pressed again — a
/// second answer would write the server's rendezvous twice, and a decline would
/// tear down a call that is mid-join whose credential has already been spent. It
/// is also visible: the button has to stop looking pressable, and there is a real
/// gap to fill (one authenticated request plus a room join) that a ringing screen
/// would otherwise spend looking frozen.
public enum IncomingCallPhase: Sendable, Equatable {
    /// Nothing is ringing and nothing is live. The screen draws nothing.
    case idle

    /// The phone is ringing. ⚠️ Bounded — see
    /// ``IncomingCallController/ringTimeoutMilliseconds``.
    case ringing

    /// Answer was pressed; the credential is being fetched and the room joined.
    case answering

    /// Media is up. ⚠️ The duration runs from this moment, not from the press.
    case inCall

    /// Over, for any reason.
    case ended(CallEndReason)
}

/// One inbound call, as a screen sees it.
public struct IncomingCallState: Sendable, Equatable {
    public internal(set) var phase: IncomingCallPhase = .idle

    /// ⚠️ Set from the push and sent back verbatim on the answer.
    public internal(set) var workspaceID: WorkspaceID?
    public internal(set) var callID: CallID?

    /// ⚠️ nil UNTIL MEDIA IS UP, which is what stops a ringing screen drawing a
    /// duration or offering mute and speaker for an engine that does not exist.
    public internal(set) var media: CallMediaState?

    /// When the ring started, in milliseconds, as the caller's own clock reported
    /// it.
    ///
    /// ⛔ A TIMESTAMP RATHER THAN A COUNTDOWN, so the timeout is a pure function
    /// of an INJECTED clock and needs no sleeping task to test. See
    /// ``ringHasExpired(atMilliseconds:)``.
    public internal(set) var ringStartedAtMilliseconds: Int64?

    /// Whether a ``CallCommand/connect(url:token:)`` has been issued for this
    /// call.
    ///
    /// ⛔ IT IS WHAT DECIDES WHETHER AN EXIT DISCONNECTS, AND IT IS NOT THE SAME
    /// QUESTION AS ``media``. `media` appears only once the room is joined, so a
    /// join that was issued and then FAILED would leave an engine holding a
    /// socket that nothing ever told to let go. ⚠️ It is also what keeps a
    /// decline and a timeout emitting byte-identical command lists: neither has
    /// ever issued a connect.
    public internal(set) var engineAttached = false

    public init() {}

    /// Whether the local ring has run out at `now`.
    ///
    /// ⚠️ FALSE IN EVERY PHASE BUT ``IncomingCallPhase/ringing``, so a timeout
    /// armed at the press cannot tear down a conversation thirty seconds in. The
    /// driver should cancel its timer as well; this is the second half, because a
    /// cancelled timer is a promise and this is a fact.
    public func ringHasExpired(atMilliseconds now: Int64) -> Bool {
        guard case .ringing = phase else { return false }
        guard let started = ringStartedAtMilliseconds else { return false }
        return now - started >= IncomingCallController.ringTimeoutMilliseconds
    }
}

/// Why the server would not let this device answer.
public enum IncomingAnswerRejection: Sendable, Equatable {
    /// The call was already over. ⚠️ NOT AN ERROR AND NOT TO BE WORDED AS ONE:
    /// the overwhelmingly common way to reach this is that the caller hung up
    /// between the phone ringing and a thumb arriving.
    case callerGone

    /// A refusal with something to say, e.g. a viewer's 403.
    case refused(message: String?)

    var endReason: CallEndReason {
        switch self {
        case .callerGone:
            .callerCancelled
        case let .refused(message):
            .answerRefused(message: message)
        }
    }
}

/// Everything that can happen to an inbound call.
public enum IncomingCallEvent: Sendable, Equatable {
    /// A push says a call is ringing for this workspace.
    case ringing(workspace: WorkspaceID, call: CallID, atMilliseconds: Int64)

    /// Answer, from the notification, the ringing screen or a system surface.
    ///
    /// ⚠️ ONE EVENT FOR ALL THREE, DELIBERATELY. A car head unit, a watch or a
    /// headset answers through CallKit, and without that wire the OS connection
    /// would go active while this app never joined the room — silence, on a call
    /// the system says is connected.
    case answerPressed

    /// The answer route minted a credential pair. ⛔ Both halves verbatim.
    case answerJoinable(url: String, token: String)

    /// The answer route refused.
    case answerRejected(IncomingAnswerRejection)

    case declinePressed

    /// The local ring bound elapsed. ⚠️ Sent by whatever owns the clock; see
    /// ``IncomingCallState/ringHasExpired(atMilliseconds:)``.
    case ringTimedOut

    case hangUpPressed

    /// The user left the ended-call summary.
    case dismissed

    case engine(CallEngineEvent)
    case muteToggled
    case speakerToggled

    /// One second of a connected call. See ``SoftphoneEvent/tick``.
    case tick
}

/// What an inbound call asks the app to do.
///
/// ⛔ THE DEVICE SURFACES ARE COMMANDS RATHER THAN CALLS FOR THE SAME REASON THE
/// ENGINE'S ARE: CallKit cannot be imported here, cannot be built on Linux and
/// cannot be exercised anywhere without a signed build on a real phone. Every
/// ordering that matters — the ring notification going away at the PRESS rather
/// than at the connect, the OS being told the call is active only AFTER media
/// is up — is an assertion about this list.
public enum IncomingCallCommand: Sendable, Equatable {
    /// Report a new incoming call to the OS and draw the notification.
    ///
    /// ⚠️ BOTH, AS ONE COMMAND, BECAUSE LOSING THE OS HALF MUST NOT LOSE THE
    /// CALL. The Kotlin client posts its heads-up notification even when Telecom
    /// refuses the connection, so the user can still answer; the same
    /// degraded-first rule applies here and belongs to whoever performs this,
    /// not to a second command a caller could forget.
    case startRinging(workspace: WorkspaceID, call: CallID)

    /// Take the ring notification away.
    ///
    /// ⛔ ISSUED AT THE PRESS, NOT AT THE CONNECT, AND THE GAP IS WHERE THE BUG
    /// WAS ON THE OTHER CLIENT. Leaving it up during the answer round trip leaves
    /// an Answer/Decline pair on screen for a call that is already being joined:
    /// Decline would tear down a call whose credential has been spent, and Answer
    /// would be a second answer. The notification is deliberately not swipeable,
    /// so the user cannot get rid of it themselves.
    case stopRinging

    /// `POST /api/district/calls/{callId}/answer?workspaceId=`.
    ///
    /// ⛔ EMITTED EXACTLY ONCE PER CALL, AND ON NO OTHER PATH. ⛔ NOTHING IS SENT
    /// ON A DECLINE OR A TIMEOUT — see ``IncomingCallController``.
    case requestAnswer(workspace: WorkspaceID, call: CallID)

    /// Tell the OS the call is connected.
    ///
    /// ⛔ AFTER MEDIA, NEVER AT THE PRESS. Marking the connection active while
    /// the credential is still being fetched starts the OS's own duration counter
    /// early and, on a failed join, leaves the user looking at a connected call
    /// with no audio.
    case reportCallActive

    /// Tell the OS the call is over. ⚠️ Idempotent by contract, and issued on
    /// every terminal path including ones where nothing was ever connected.
    case reportCallEnded

    case engine(CallCommand)
}

/// The inbound state machine: ring, answer, decline, time out.
///
/// ⛔ **NOTHING IS SENT TO THE SERVER ON A DECLINE OR A TIMEOUT, AND THAT IS A
/// PRIVACY PROPERTY RATHER THAN AN OMISSION.** `POST
/// /api/district/actions/ring-app` blocks on a Redis rendezvous for about 25
/// seconds and falls back to PSTN when it expires, so the server already has
/// everything it needs from the ABSENCE of an answer. Reporting a decline would
/// make a deliberate refusal distinguishable from a phone in a pocket — to the
/// agent, and through it to the caller — and there is no version of that
/// distinction the product wants. The two must be indistinguishable from outside,
/// so they emit identical command lists and differ only in a local
/// ``CallEndReason`` this device never transmits.
///
/// ⛔ **THE RING IS BOUNDED LOCALLY AND THE BOUND IS LONGER THAN THE SERVER'S ON
/// PURPOSE.** The rendezvous expires at 25s; this waits 30. Timing out FIRST
/// would take the Answer button away while the server was still willing to accept
/// one, which is the one ordering that turns a slow thumb into a missed call.
///
/// ⛔ **ONE CALL AT A TIME, AND A SECOND PUSH WHILE ONE IS LIVE IS DROPPED** —
/// not queued, not allowed to replace. One engine owns the device's audio focus,
/// and a replacement would tear down a conversation the user is having in order to
/// ring them about another. The dropped call still reaches the server's timeout
/// and falls back to PSTN, which is the correct outcome for a person who is
/// already on the phone.
///
/// ⛔ **THE ANSWER SIGNAL IS OUR OWN MEDIA COMING UP, NOT A PARTICIPANT
/// APPEARING**, which is the whole reason this is not ``SoftphoneSession``. An
/// inbound call joins a room that ALREADY contains the caller and the AI, so
/// participants are present from the first frame and a machine that latched on
/// them would report "answered" before it had connected to anything.
/// ``CallEngineEvent/participantJoined(_:)`` and
/// ``CallEngineEvent/participantLeft(_:)`` are therefore counted here and decide
/// nothing.
public struct IncomingCallController: Sendable, Equatable {
    /// ⛔ LONGER THAN THE SERVER'S 25s RENDEZVOUS, ON PURPOSE. See the type note.
    public static let ringTimeoutMilliseconds: Int64 = 30000

    public private(set) var state = IncomingCallState()

    public init() {}

    @discardableResult
    public mutating func handle(_ event: IncomingCallEvent) -> [IncomingCallCommand] {
        let outcome = Self.reduce(state, event)
        state = outcome.state
        return outcome.commands
    }

    /// The reducer. Pure, total, and the only place a phase changes.
    public static func reduce(
        _ state: IncomingCallState,
        _ event: IncomingCallEvent
    ) -> (state: IncomingCallState, commands: [IncomingCallCommand]) {
        switch state.phase {
        case .idle:
            reduceIdle(state, event)
        case .ringing:
            reduceRinging(state, event)
        case .answering:
            reduceAnswering(state, event)
        case .inCall:
            reduceInCall(state, event)
        case .ended:
            reduceEnded(state, event)
        }
    }

    private static func reduceIdle(
        _ state: IncomingCallState,
        _ event: IncomingCallEvent
    ) -> (state: IncomingCallState, commands: [IncomingCallCommand]) {
        guard case let .ringing(workspace, call, startedAt) = event else { return (state, []) }
        var next = state
        next.phase = .ringing
        next.workspaceID = workspace
        next.callID = call
        next.ringStartedAtMilliseconds = startedAt
        return (next, [.startRinging(workspace: workspace, call: call)])
    }

    private static func reduceRinging(
        _ state: IncomingCallState,
        _ event: IncomingCallEvent
    ) -> (state: IncomingCallState, commands: [IncomingCallCommand]) {
        switch event {
        case .answerPressed:
            answer(state)
        case .declinePressed:
            end(state, .declined)
        case .ringTimedOut:
            // ⛔ THE SAME PATH AS A DECLINE, NOT MERELY THE SAME BEHAVIOUR TODAY.
            // See the type note: sharing the exit is what guarantees the two stay
            // indistinguishable from outside.
            end(state, .ringTimedOut)
        case .hangUpPressed:
            end(state, .hungUpLocally)
        case .ringing:
            // ⛔ A SECOND PUSH IS DROPPED. See the type note.
            (state, [])
        default:
            (state, [])
        }
    }

    private static func answer(
        _ state: IncomingCallState
    ) -> (state: IncomingCallState, commands: [IncomingCallCommand]) {
        guard let workspace = state.workspaceID, let call = state.callID else { return (state, []) }
        var next = state
        next.phase = .answering
        // ⛔ THE NOTIFICATION GOES FIRST, SYNCHRONOUSLY WITH THE PRESS. See
        // ``IncomingCallCommand/stopRinging``.
        return (next, [.stopRinging, .requestAnswer(workspace: workspace, call: call)])
    }

    private static func reduceAnswering(
        _ state: IncomingCallState,
        _ event: IncomingCallEvent
    ) -> (state: IncomingCallState, commands: [IncomingCallCommand]) {
        switch event {
        case let .answerJoinable(url, token):
            var next = state
            next.engineAttached = true
            return (next, [.engine(.connect(url: url, token: token))])
        case let .answerRejected(rejection):
            return end(state, rejection.endReason)
        case let .engine(engineEvent):
            return reduceAnsweringEngine(state, engineEvent)
        case .declinePressed, .hangUpPressed:
            return end(state, .hungUpLocally)
        case .answerPressed:
            // ⛔ A SECOND ANSWER IS DROPPED. The notification's button, the
            // on-screen button and a car head unit can all fire, and the OS can
            // deliver one twice; a second round trip would write the server's
            // rendezvous again for a call that is already being joined.
            return (state, [])
        case .ringTimedOut:
            // ⛔ THE TIMEOUT DOES NOT FIRE AFTER THE PRESS. Left live it would
            // tear down a conversation thirty seconds in, for no reason the user
            // could observe.
            return (state, [])
        default:
            return (state, [])
        }
    }

    private static func reduceAnsweringEngine(
        _ state: IncomingCallState,
        _ event: CallEngineEvent
    ) -> (state: IncomingCallState, commands: [IncomingCallCommand]) {
        switch event {
        case .connected:
            var next = state
            next.phase = .inCall
            next.media = CallMediaState()
            // ⚠️ UNCONDITIONALLY UNMUTED. The answer route excludes viewers
            // server-side, and unlike a meeting there is no listen-only seat
            // worth having on a telephone call: the caller would experience it as
            // silence.
            return (next, [.engine(.setMuted(false)), .reportCallActive])
        case let .failed(message):
            return end(state, .failed(message: message))
        case let .disconnected(reason):
            return end(state, .remoteEnded(reason: reason))
        default:
            return (state, [])
        }
    }

    private static func reduceInCall(
        _ state: IncomingCallState,
        _ event: IncomingCallEvent
    ) -> (state: IncomingCallState, commands: [IncomingCallCommand]) {
        switch event {
        case .hangUpPressed, .declinePressed:
            return end(state, .hungUpLocally)
        case let .engine(engineEvent):
            return reduceInCallEngine(state, engineEvent)
        case .muteToggled:
            guard let media = state.media else { return (state, []) }
            return (state, [.engine(media.muteToggleCommand())])
        case .speakerToggled:
            return toggleSpeaker(state)
        case .tick:
            var next = state
            next.media?.elapsedSeconds += 1
            return (next, [])
        default:
            return (state, [])
        }
    }

    private static func reduceInCallEngine(
        _ state: IncomingCallState,
        _ event: CallEngineEvent
    ) -> (state: IncomingCallState, commands: [IncomingCallCommand]) {
        switch event {
        case let .failed(message):
            return end(state, .failed(message: message))
        case let .disconnected(reason):
            return end(state, .remoteEnded(reason: reason))
        default:
            var next = state
            next.media?.apply(event)
            return (next, [])
        }
    }

    private static func reduceEnded(
        _ state: IncomingCallState,
        _ event: IncomingCallEvent
    ) -> (state: IncomingCallState, commands: [IncomingCallCommand]) {
        // ⛔ ENDED IS A STATE THE USER LEAVES, NOT ONE THAT EXPIRES. A call that
        // vanished on hang-up would answer "what happened, how long was that"
        // with nothing. Everything else here is absorbed, which is what makes a
        // late engine event and a second hang-up cost no command.
        guard case .dismissed = event else { return (state, []) }
        return (IncomingCallState(), [])
    }

    private static func toggleSpeaker(
        _ state: IncomingCallState
    ) -> (state: IncomingCallState, commands: [IncomingCallCommand]) {
        guard var media = state.media else { return (state, []) }
        let command = media.toggleSpeaker()
        var next = state
        next.media = media
        return (next, [.engine(command)])
    }

    /// The one exit.
    ///
    /// ⛔ THE DISCONNECT IS APPENDED ONLY WHEN A CONNECT WAS EVER ISSUED. See
    /// ``IncomingCallState/engineAttached`` — it is what keeps a declined ring and
    /// a timed-out one emitting the same two commands, and what stops a failed
    /// join leaving a socket nobody closes.
    private static func end(
        _ state: IncomingCallState,
        _ reason: CallEndReason
    ) -> (state: IncomingCallState, commands: [IncomingCallCommand]) {
        var next = state
        next.phase = .ended(reason)
        var commands: [IncomingCallCommand] = [.stopRinging, .reportCallEnded]
        if state.engineAttached {
            commands.append(.engine(.disconnect))
        }
        return (next, commands)
    }
}
