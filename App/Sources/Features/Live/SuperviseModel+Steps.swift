import DistrictCall
import DistrictModel
import DistrictNetwork
import Foundation

/// How ``SuperviseModel`` answers the OS and performs the reducer's commands.
///
/// ⚠️ SPLIT OUT OF `SuperviseModel.swift` FOR `type_body_length`, AND THAT IS THE WHOLE REASON,
/// the call `DialerTasks.swift` makes about the dialler. ⛔ IT WRITES NO `private(set)` STATE:
/// the session, the start and its refusal are written in the model's own file (``apply(_:)``,
/// ``began(uuid:)``, ``release()``), and the members this file writes are the module-visible
/// ones the model lists.
extension SuperviseModel {
    // MARK: - What the system asks for

    /// ⛔ EVERY CASE ORIGINATES OUTSIDE THIS APP: the lock screen, a headset, CarPlay. A request
    /// that did not reach the reducer would leave the OS believing one thing and the media doing
    /// another.
    func system(_ request: CallKitRequest) {
        switch request {
        case let .dialRequested(uuid):
            guard uuid == callUUID else { return }
            Task { await began(uuid: uuid) }
        case let .endRequested(uuid):
            guard uuid == callUUID else { return }
            Task { await systemEnded() }
        case let .muteRequested(uuid, muted):
            guard uuid == callUUID else { return }
            // ⛔ AN ABSOLUTE REQUEST MEETS A TOGGLE EVENT: applied only when the two disagree.
            guard state.holdsTheCall, state.media.microphoneEnabled == muted else { return }
            Task { await apply(.muteToggled) }
        case .answerRequested:
            // ⚠️ INBOUND, AND NEVER THIS MODEL'S: ``IncomingCallModel`` owns an answer.
            break
        case .reset:
            Task { await systemEnded() }
        }
    }

    /// The OS ended the call, or the provider reset: the person left.
    private func systemEnded() async {
        if starting {
            await release()
            return
        }
        await apply(.stopPressed)
    }

    func perform(_ command: SuperviseCommand) async {
        switch command {
        case .requestListen:
            await requestListen()
        case .requestTakeover:
            await requestTakeover()
        case let .join(leg, generation, url, token):
            await join(leg, generation: generation, url: url, token: token)
        case let .engine(leg, engineCommand):
            // ⛔ A COMMAND FOR A LEG WHOSE ENGINE IS GONE IS DROPPED: there is one slot, and it
            // may already hold the other leg's engine.
            guard leg == engineLeg else { return }
            await media.perform(engineCommand)
        case .reportCallEnded:
            if let callUUID {
                media.reportEnded(uuid: callUUID)
            }
        }
    }

    /// ⛔ ONCE PER PRESS, NEVER RETRIED: a seat that arrives after the person gave up would join
    /// them to a customer's call they had walked away from. The reducer absorbs a late answer.
    private func requestListen() async {
        guard let id = SupervisedCallID(callId) else {
            // ⚠️ UNREACHABLE FOR A CALL-LOG ROW (a `Call.id` carries no `_`); refused all the
            // same, as `calls/token` would read such a value as a room.
            await apply(.listenRefused(.decoding("call id is not a call")))
            return
        }
        switch await server.monitor(callId: id, platform: .ios) {
        case let .success(seat):
            await apply(.listenGranted(seat))
        case let .failure(error):
            await apply(.listenRefused(error))
        }
    }

    private func requestTakeover() async {
        switch await server.takeOver(workspaceId: workspaceId, callId: callId) {
        case let .success(seat):
            await apply(.takeoverGranted(seat))
        case let .failure(error):
            await apply(.takeoverRefused(error))
        }
    }

    /// Build the leg's engine, read its events, then connect it.
    ///
    /// ⛔ THE ENGINE EXISTS BEFORE THE CONNECT, because ``SuperviseMedia/perform(_:)`` drops a
    /// command that arrives with none. ⛔ EACH ENGINE'S STREAM IS READ ONCE, AND EVERY EVENT
    /// CARRIES THE LEG AND THE GENERATION ITS JOIN WAS GIVEN, so the session drops what a left
    /// engine says late: the listen engine's `disconnected` after a takeover, or a stopped
    /// listen's after Listen was pressed again.
    private func join(_ leg: SuperviseLeg, generation: Int, url: String, token: String) async {
        legTask?.cancel()
        let events = await media.beginLeg(leg)
        engineLeg = leg
        legTask = Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { return }
                await apply(.engine(leg, generation: generation, event))
            }
        }
        await media.perform(.connect(url: url, token: token))
    }

    /// React to the phase the reducer has just reached.
    func settle() async {
        switch state.phase {
        case .listening, .takenOver:
            reportConnected()
        case .idle, .over:
            // ⛔ NOT WHILE THE OS IS STILL STARTING THE CALL: a note sent in that second is an
            // event in `idle` too, and releasing then would drop the listen-in just pressed.
            guard !starting else { return }
            await release()
        case .requestingListen, .joiningListen, .requestingTakeover, .joiningTakeover:
            break
        }
    }

    /// ⛔ ONCE: `reportOutgoingCall(uuid:connectedAt:)` starts the OS's duration counter.
    private func reportConnected() {
        guard !connectedReported, let callUUID else { return }
        connectedReported = true
        media.reportConnected(uuid: callUUID)
    }
}
