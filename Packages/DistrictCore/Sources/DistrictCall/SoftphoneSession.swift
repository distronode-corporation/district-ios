import DistrictModel

/// Where an OUTBOUND call is.
///
/// ⛔ ``ringing`` IS ITS OWN PHASE BECAUSE "IN THE ROOM" AND "ON THE PHONE" ARE
/// DIFFERENT FACTS. `POST /api/district/calls/dial` returns as soon as the
/// carrier accepts, so this device is in the room hearing ring-back long before
/// anybody picks up. Collapsing it into ``connected`` would run a duration while
/// the callee's handset was still ringing, and the number on screen would not be
/// the number they are billed for.
///
/// ⚠️ ``ended(_:)`` COVERS BOTH A NORMAL END AND A MEDIA FAILURE, which the
/// Kotlin client models as two phases. The reason carries the difference, and
/// carrying it in the phase's payload is what stops a screen deriving
/// "did it fail" from a connection state that also says `Disconnected` for an
/// ordinary hang-up.
public enum SoftphonePhase: Sendable, Equatable {
    /// The keypad. No call exists.
    case idle

    /// The dial request is out. ⚠️ Nothing is joined and no engine exists yet.
    case dialing

    /// The server answered with a credential pair and the room is being joined.
    case connecting

    /// In the room, waiting for the callee to pick up. ⚠️ No timer runs here.
    case ringing

    /// The callee is on the line and the duration is running.
    case connected

    /// Over. See ``CallEndReason``.
    case ended(CallEndReason)
}

/// Everything one outbound call is.
public struct SoftphoneState: Sendable, Equatable {
    public internal(set) var phase: SoftphonePhase = .idle

    /// ⚠️ AS THE OPERATOR TYPED IT. The server normalised its own copy and ran
    /// the DNC check and the dial against THAT form; this is the string the
    /// operator will recognise, and it never travels.
    public let number: String

    public internal(set) var media = CallMediaState()

    /// ⛔ LATCHED AT THE FIRST PARTICIPANT AND NEVER RECOMPUTED. Once answered, a
    /// room that empties means the callee hung up rather than that they were
    /// never there — a flag that fell back to false would redraw the ringing UI
    /// over a call that had just ended and restart the duration from zero. It
    /// survives into ``SoftphonePhase/ended(_:)`` because it is what says whether
    /// ``CallMediaState/elapsedSeconds`` is a billed length or a zero.
    public internal(set) var answered = false

    /// The server's id for this call, or nil until the dial has been accepted.
    ///
    /// ⛔ THE ONLY THING THAT CAN END THE CARRIER LEG, AND IT ARRIVES LATE. It is
    /// unknown for the whole of ``SoftphonePhase/dialing``, which is precisely the
    /// window an operator hangs up in when they mis-dial — so a design that could
    /// only spend it while a call was live would miss the case it exists for. See
    /// ``SoftphoneServerLeg`` for how a credential arriving AFTER the ending is
    /// still spent.
    public internal(set) var callId: String?

    /// Whether the server has already been asked to end this call's carrier leg.
    ///
    /// ⛔ A LATCH, NOT A DERIVED FACT, AND IT IS WHAT MAKES "EXACTLY ONCE" TRUE
    /// ACROSS TWO DIFFERENT EXITS. The request is emitted by the ordinary ending
    /// AND by a late ``SoftphoneEvent/dialAccepted(url:token:callId:)`` that lands
    /// in ``SoftphonePhase/ended(_:)``; only one of those can be first, and without
    /// a latch a hang-up during `connecting` followed by a redelivered credential
    /// would send two. ⚠️ It is set when the request is EMITTED rather than when it
    /// answers, deliberately: the request is best effort and fire-and-forget, so
    /// there is no answer to wait for and a latch that waited for one would be a
    /// latch that never closed.
    public internal(set) var serverHangUpRequested = false

    public init(number: String) {
        self.number = number
    }
}

/// Everything that can happen to an outbound call.
public enum SoftphoneEvent: Sendable, Equatable {
    /// The operator pressed Call.
    case dialRequested

    /// The dial was refused before a call existed: a 403 for a viewer, a 402 for
    /// a lapsed subscription, a DNC hit, a number the route rejected.
    ///
    /// ⛔ IT RETURNS TO ``SoftphonePhase/idle`` RATHER THAN ENDING A CALL,
    /// because no call was ever placed and there is nothing to show a message
    /// over. The refusal belongs on the keypad. This is the one event whose
    /// wording matters more than its transition: an ``SoftphonePhase/ended(_:)``
    /// here would draw a call summary for a call that never happened.
    case dialRefused

    /// The server minted a credential pair. ⛔ Both halves verbatim.
    ///
    /// ⛔ IT CARRIES THE `callId` TOO, AND THAT IS NOT BOOKKEEPING. Without it the
    /// reducer never learns the id and nothing in the machine can ask the server
    /// to end the carrier leg — which is the whole of the billing defect recorded
    /// on ``DialResponse/callId``. The id is the ONLY handle on the SIP participant;
    /// the room name is not one, and no client mints either.
    case dialAccepted(url: String, token: String, callId: String)

    /// Something the media session reported.
    case engine(CallEngineEvent)

    /// The operator hung up, or the OS's own end-call affordance fired.
    case hangUpPressed

    case muteToggled
    case speakerToggled

    /// One second of a call that has been answered.
    ///
    /// ⚠️ THE TIMER'S GRANULARITY, NOT A POLL — nothing is fetched. The clock
    /// lives in whatever drives this; putting a sleep in here would make every
    /// duration assertion wait in real time.
    case tick
}

public extension SoftphoneEvent {
    /// Build ``dialAccepted(url:token:)`` from the route's own body.
    ///
    /// ⛔ IT READS THREE FIELDS AND NOTHING ELSE. The dial body is a credential
    /// pair rather than a data shape, plus ``DialResponse/callId``, which is not
    /// decoration on a credential: it is the ONLY handle this client will ever
    /// have on the carrier leg, and leaving it at the repository means a call the
    /// operator ended goes on being billed. ``DialResponse/roomName`` and
    /// ``DialResponse/success`` stay out, which is what the rule was for.
    ///
    /// ⚠️ The rest is unchanged: the server has already written the `Call` row and
    /// already told the carrier to dial by the time it mints a credential, so there
    /// is no retry — retrying places a SECOND call. Naming the DTO here keeps the
    /// "used verbatim" rule in one place instead of at every caller.
    static func dialAccepted(_ response: DialResponse) -> SoftphoneEvent {
        .dialAccepted(url: response.url, token: response.token, callId: response.callId)
    }
}

/// The outbound state machine: `idle → dialing → connecting → ringing →
/// connected → ended(reason)`.
///
/// ⛔ A PURE REDUCER PLUS A `mutating` DRIVER, WITH NO CLOCK, NO TASK AND NO
/// ACTOR. Every transition below is a synchronous function of a state and an
/// event, so the illegal ones are as testable as the legal ones and neither
/// needs a media server, a carrier or a device. The Kotlin equivalent
/// (`SoftphoneSession.kt`) is a coroutine-scoped object whose tests carry three
/// paragraphs about `runTest` hanging on a `while (true) { delay(tick) }` ticker
/// — that hazard cannot exist here because the ticker is an event.
///
/// ⛔ ONE SESSION PER CALL, NEVER A REUSED ONE. ``SoftphonePhase/ended(_:)`` is
/// terminal and absorbs everything, which is what makes "hang up disconnects
/// exactly once" true: a second hang-up, a late engine event and an OS end-call
/// callback that arrives after the fact all produce no command at all. ⚠️ It is
/// also what makes "the OS is told exactly once" true, now that
/// ``SoftphoneCommand/reportCallEnded`` shares that exit.
public struct SoftphoneSession: Sendable, Equatable {
    public private(set) var state: SoftphoneState

    public init(number: String) {
        state = SoftphoneState(number: number)
    }

    /// Apply one event and return what the app must do.
    ///
    /// ⚠️ THE COMMANDS ARE ORDERED AND THE ORDER IS PART OF THE CONTRACT. See
    /// ``CallCommand`` for the engine half and ``SoftphoneCommand`` for the
    /// CallKit half.
    @discardableResult
    public mutating func handle(_ event: SoftphoneEvent) -> [SoftphoneCommand] {
        let outcome = Self.reduce(state, event)
        state = outcome.state
        return outcome.commands
    }

    /// The reducer. Pure, total, and the only place a phase changes.
    public static func reduce(
        _ state: SoftphoneState,
        _ event: SoftphoneEvent
    ) -> (state: SoftphoneState, commands: [SoftphoneCommand]) {
        switch state.phase {
        case .idle:
            reduceIdle(state, event)
        case .dialing:
            reduceDialing(state, event)
        case .connecting:
            reduceConnecting(state, event)
        case .ringing:
            reduceRinging(state, event)
        case .connected:
            reduceConnected(state, event)
        case .ended:
            // ⛔ TERMINAL, AND IT ABSORBS EVERYTHING INCLUDING A SECOND HANG-UP
            // AND A LATE ENGINE EVENT. That is what makes the disconnect exactly
            // once rather than once per path that reaches it.
            //
            // ⛔ WITH EXACTLY ONE EXCEPTION, AND IT IS THE CASE THE BILLING
            // DEFECT LIVES IN. A credential that arrives after the
            // ending carries the one thing the machine still needs — the `callId`
            // — so it is absorbed for every purpose but that one. See
            // `SoftphoneServerLeg.swift`, which is where the whole argument is.
            reduceEnded(state, event)
        }
    }

    private static func reduceIdle(
        _ state: SoftphoneState,
        _ event: SoftphoneEvent
    ) -> (state: SoftphoneState, commands: [SoftphoneCommand]) {
        // ⚠️ EVERY OTHER EVENT IS DROPPED RATHER THAN TRAPPED. A recomposition
        // can fire a handler against a call that has already gone, and throwing
        // would crash the process over a stale tap.
        guard case .dialRequested = event else { return (state, []) }
        var next = state
        next.phase = .dialing
        return (next, [])
    }

    private static func reduceDialing(
        _ state: SoftphoneState,
        _ event: SoftphoneEvent
    ) -> (state: SoftphoneState, commands: [SoftphoneCommand]) {
        switch event {
        case .dialRefused:
            // ⛔ BACK TO THE KEYPAD. No call was placed. See the event's note.
            //
            // ⛔ AND THE OS IS TOLD. "No call was placed" is true of the CARRIER and false of
            // CallKit: the dial only goes out once a `CXStartCallAction` has been
            // PERFORMED, so by the time a refusal can exist at all the system is
            // already holding a call. Every coded refusal reaches here — a DNC hit,
            // a 402, a dormant workspace, a handset that is simply offline — and
            // without the report each one leaves that call standing forever.
            var next = state
            next.phase = .idle
            return (next, [.reportCallEnded])
        case let .dialAccepted(url, token, callId):
            var next = state
            next.phase = .connecting
            // ⛔ RECORDED BEFORE ANYTHING CAN END, WHICH IS THE ONLY ORDER THAT
            // WORKS. From here every exit can reach the carrier; a session that
            // learned the id later would have a window in which a hang-up was
            // local-only, and that window is where the money went.
            next.callId = callId
            return (next, [.engine(.connect(url: url, token: token))])
        case .hangUpPressed:
            return end(state, .hungUpLocally)
        default:
            return (state, [])
        }
    }

    private static func reduceConnecting(
        _ state: SoftphoneState,
        _ event: SoftphoneEvent
    ) -> (state: SoftphoneState, commands: [SoftphoneCommand]) {
        switch event {
        case .hangUpPressed:
            end(state, .hungUpLocally)
        case let .engine(engineEvent):
            reduceConnectingEngine(state, engineEvent)
        case .muteToggled:
            (state, [.engine(state.media.muteToggleCommand())])
        case .speakerToggled:
            toggleSpeaker(state)
        default:
            (state, [])
        }
    }

    private static func reduceConnectingEngine(
        _ state: SoftphoneState,
        _ event: CallEngineEvent
    ) -> (state: SoftphoneState, commands: [SoftphoneCommand]) {
        switch event {
        case .connected:
            var next = state
            next.phase = .ringing
            next.media.apply(event)
            // ⚠️ UNCONDITIONALLY UNMUTED, unlike a meeting room's `canPublish`
            // gate: the dial route excludes viewers server-side, so a token that
            // reached here always carries publish rights. ⚠️ And this reducer
            // ASSUMES the microphone was granted; it cannot ask. The App's
            // `DialerModel` asks before CallKit or the dial route hears of the
            // call and places nothing on a refusal, so the dialler cannot bring
            // a denied microphone to this line.
            return (next, [.engine(.setMuted(false))])
        case let .failed(message):
            return end(state, .failed(message: message))
        case let .disconnected(reason):
            return end(state, .remoteEnded(reason: reason))
        default:
            return (applyMedia(state, event), [])
        }
    }

    private static func reduceRinging(
        _ state: SoftphoneState,
        _ event: SoftphoneEvent
    ) -> (state: SoftphoneState, commands: [SoftphoneCommand]) {
        switch event {
        case .hangUpPressed:
            end(state, .hungUpLocally)
        case let .engine(engineEvent):
            reduceRingingEngine(state, engineEvent)
        case .muteToggled:
            (state, [.engine(state.media.muteToggleCommand())])
        case .speakerToggled:
            toggleSpeaker(state)
        default:
            // ⛔ A `tick` HERE COUNTS NOTHING. See ``CallMediaState/elapsedSeconds``.
            (state, [])
        }
    }

    private static func reduceRingingEngine(
        _ state: SoftphoneState,
        _ event: CallEngineEvent
    ) -> (state: SoftphoneState, commands: [SoftphoneCommand]) {
        switch event {
        case .participantJoined:
            // ⛔ THE ANSWER, AND THE ONLY SIGNAL THIS CLIENT HAS FOR IT.
            var next = applyMedia(state, event)
            next.answered = true
            next.phase = .connected
            return (next, [])
        case let .failed(message):
            return end(state, .failed(message: message))
        case let .disconnected(reason):
            // ⚠️ BEFORE THE ANSWER THIS IS THE CALLEE DECLINING OR THE DIAL
            // FAILING AT THE CARRIER. It ends the call either way, and the
            // zero duration is what tells the operator which it was.
            return end(state, .remoteEnded(reason: reason))
        default:
            return (applyMedia(state, event), [])
        }
    }

    private static func reduceConnected(
        _ state: SoftphoneState,
        _ event: SoftphoneEvent
    ) -> (state: SoftphoneState, commands: [SoftphoneCommand]) {
        switch event {
        case .hangUpPressed:
            return end(state, .hungUpLocally)
        case let .engine(engineEvent):
            return reduceConnectedEngine(state, engineEvent)
        case .muteToggled:
            return (state, [.engine(state.media.muteToggleCommand())])
        case .speakerToggled:
            return toggleSpeaker(state)
        case .tick:
            var next = state
            next.media.elapsedSeconds += 1
            return (next, [])
        default:
            return (state, [])
        }
    }

    private static func reduceConnectedEngine(
        _ state: SoftphoneState,
        _ event: CallEngineEvent
    ) -> (state: SoftphoneState, commands: [SoftphoneCommand]) {
        switch event {
        case .participantLeft:
            let next = applyMedia(state, event)
            // ⛔ THE ROOM EMPTYING IS THE FAR END HANGING UP. A leave that still
            // leaves someone in the room is not: a `direct_` room holds one SIP
            // participant today, and a build that ended the call on the first
            // leave would drop a three-way the moment anyone stepped out.
            guard next.media.remoteParticipants == 0 else { return (next, []) }
            return end(next, .remoteHungUp)
        case let .failed(message):
            return end(state, .failed(message: message))
        case let .disconnected(reason):
            return end(state, .remoteEnded(reason: reason))
        default:
            return (applyMedia(state, event), [])
        }
    }

    private static func applyMedia(_ state: SoftphoneState, _ event: CallEngineEvent) -> SoftphoneState {
        var next = state
        next.media.apply(event)
        return next
    }

    private static func toggleSpeaker(
        _ state: SoftphoneState
    ) -> (state: SoftphoneState, commands: [SoftphoneCommand]) {
        var next = state
        // ⚠️ THE COMMAND IS BOUND BEFORE THE TUPLE IS BUILT. A tuple literal
        // evaluates left to right, so `(next, [next.media.toggleSpeaker()])`
        // would copy the PRE-toggle state into the first element and return a
        // command that disagrees with the state beside it.
        let command = next.media.toggleSpeaker()
        return (next, [.engine(command)])
    }

    /// The one exit. ⛔ Exactly one ``CallCommand/disconnect``, on every path.
    private static func end(
        _ state: SoftphoneState,
        _ reason: CallEndReason
    ) -> (state: SoftphoneState, commands: [SoftphoneCommand]) {
        var next = state
        next.phase = .ended(reason)
        // ⛔ THE CARRIER LEG IS ENDED ON EVERY REASON, NOT ONLY THE LOCAL ONES, AND
        // THAT IS DELIBERATE RATHER THAN LAZY. ``exitCommands(for:)`` above splits
        // the endings the OS performed from the ones it cannot see; the SERVER can
        // see none of them. ``CallEndReason/remoteHungUp`` is the one case where
        // the leg is genuinely already down, and the route answers that with
        // `{ended: false}` at no cost — whereas ``CallEndReason/failed(message:)``
        // and ``CallEndReason/remoteEnded(reason:)`` mean OUR socket died, which
        // says nothing at all about the telephone. Guessing which of the three is
        // which, wrongly, is a bill.
        //
        // ⚠️ THE COMMANDS ARE BOUND BEFORE THE TUPLE IS BUILT, for the reason
        // ``toggleSpeaker(_:)`` states: the helper MUTATES `next` (it closes the
        // latch), and a tuple literal evaluates left to right, so `(next, withServer
        // HangUp(&next, …))` would return the pre-latch state beside a command that
        // had already spent it.
        let commands = withServerHangUp(&next, exitCommands(for: reason))
        return (next, commands)
    }

    /// What an ending owes the app, decided from the reason alone.
    ///
    /// ⛔ THE REPORT GOES BEFORE THE DISCONNECT, matching
    /// ``IncomingCallController``: the system's own call UI should come down as
    /// the call ends rather than after a socket has finished closing, and the
    /// disconnect is fire-and-forget at the far end of the app anyway.
    ///
    /// ⚠️ INTERNAL RATHER THAN PRIVATE SO IT CAN BE ASSERTED DIRECTLY. The
    /// interesting half of this function is the arm nothing reaches (see below),
    /// and a `private` helper would be both untestable and uncovered.
    static func exitCommands(for reason: CallEndReason) -> [SoftphoneCommand] {
        switch reason {
        // ⛔ NO REPORT, AND IT IS A DECISION RATHER THAN AN OMISSION. See the ⛔ on
        // ``SoftphoneCommand``: every producer of ``SoftphoneEvent/hangUpPressed``
        // has already put a `CXEndCallAction` through CallKit, so a report here
        // would tell the OS about an ending it performed itself.
        case .hungUpLocally:
            [.engine(.disconnect)]
        // ⛔ THE MEDIA LAYER TALKING, WHICH CALLKIT CANNOT SEE. The callee hanging
        // up, the room dropping and a join that failed are all invisible to the
        // OS, so this list is the only thing that ends the system's call.
        case .remoteHungUp, .remoteEnded, .failed:
            [.reportCallEnded, .engine(.disconnect)]
        // ⚠️ NOT REACHABLE ON AN OUTBOUND CALL, AND ANSWERED ANYWAY RATHER THAN
        // DEFAULTED. All four belong to ``IncomingCallController``. Writing them
        // out is what makes a NEW ``CallEndReason`` a compile error here rather
        // than an ending that is silently never reported — which is the exact
        // shape of the defect this function was added to close.
        case .declined, .ringTimedOut, .callerCancelled, .answerRefused:
            [.reportCallEnded, .engine(.disconnect)]
        }
    }
}
