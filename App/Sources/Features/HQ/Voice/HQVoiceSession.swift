import DistrictData
import DistrictModel
import Foundation
import Observation

/// One District HQ voice session, from the member's tap to its end.
///
/// ⛔ A TOKEN IS MINTED ONLY ON THE MEMBER'S TAP (``start(history:)``), never as a prefetch:
/// each one starts a billed session of at most ``HQVoice/sessionSeconds``.
///
/// ⛔ THE REGION NOTICE COMES BEFORE THE MICROPHONE. The credential's `processingRegion` is
/// shown (``Phase/notice(_:)``) and nothing is joined until the member says Start
/// (``begin()``); Cancel joins nothing and discards the session (``cancelNotice()``).
///
/// ⛔ A SESSION THAT NEVER WENT LIVE IS DISCARDED, ONE THE APP ENDS IS ENDED. A declined
/// notice and a failed join call `hq/voice-discard`; Stop, the 30 minutes, a ring and a
/// sign-out call `hq/voice-end`, so only the minutes used are counted. Both by `sessionId`.
///
/// ⛔ PUSH-TO-TALK STARTS MUTED. With ``HQMicMode/push`` the microphone opens only while the
/// button is held (``holdToTalk(_:)``); with an open mode it opens on the join.
///
/// ⛔ ONE ROOM AT A TIME WITH CALLS AND MEETINGS. Refused while ``CallStack`` holds a call or
/// a room; claims the room for its whole length, so a District call that rings ends it
/// (``yieldAudio(_:)``).
@MainActor
@Observable
final class HQVoiceSession: RoomAudio {
    enum Phase: Equatable {
        case idle
        case minting
        case notice(HQVoiceTokenResponse)
        case connecting
        case live
        case ended(EndReason)
    }

    enum EndReason: Equatable {
        case byMember
        case callArrived
        case timedOut
        case disconnected
        /// Refused before anything started: a call or a meeting holds the audio.
        case busy
        case microphoneDenied
        /// The service refused the token; its own sentence (the allowance one included).
        case refused(String)
        case failed(String)
    }

    /// A proposal the member has not resolved yet, or one just resolved.
    struct ProposalCard: Identifiable, Equatable {
        let proposal: HQVoiceProposal
        var outcome: HQResolutionStatus?
        var isWorking = false

        var id: String {
            proposal.proposalId
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var segments: [HQVoiceSegment] = []
    private(set) var agentState: HQAgentState?
    private(set) var proposals: [ProposalCard] = []
    private(set) var micMode: HQMicMode = .open
    private(set) var isMicrophoneOn = false

    let canConfirm: Bool
    let workspaceId: String
    private let hq: HQRepository
    private let callStack: CallStack
    private let microphone: any MicrophoneAccess
    private let makeEngine: @MainActor (String) -> any HQVoiceEngine
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var engine: (any HQVoiceEngine)?
    private var credential: HQVoiceTokenResponse?
    private var listening: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var microphoneChange: Task<Void, Never>?
    /// The microphone state last asked for, which ``setMicrophone(_:)`` applies in order.
    private var micWanted = false
    private var screenVersion = 0
    private var place = HQVoicePlace(.hq)

    init(
        workspaceId: String,
        canConfirm: Bool,
        hq: HQRepository,
        callStack: CallStack,
        microphone: any MicrophoneAccess,
        makeEngine: @escaping @MainActor (String) -> any HQVoiceEngine = { LiveKitHQVoiceEngine(e2eeKey: $0) },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.workspaceId = workspaceId
        self.canConfirm = canConfirm
        self.hq = hq
        self.callStack = callStack
        self.microphone = microphone
        self.makeEngine = makeEngine
        self.sleep = sleep
    }

    var isActive: Bool {
        switch phase {
        case .minting, .notice, .connecting, .live: true
        case .idle, .ended: false
        }
    }

    // MARK: - Starting

    /// The member tapped Talk: check the audio and the microphone, then mint.
    func start(history: [HQVoiceTurn], locale: String) async {
        guard !isActive else { return }
        guard !callStack.hasLiveCall, !callStack.hasLiveRoom else {
            phase = .ended(.busy)
            return
        }
        if microphone.status == .notDetermined {
            _ = await microphone.request()
        }
        guard microphone.status == .granted else {
            phase = .ended(.microphoneDenied)
            return
        }
        reset()
        phase = .minting
        let answer = await hq.voiceToken(workspaceId: workspaceId, locale: locale, history: history)
        // ⚠️ STOPPED, OR ENDED BY A RING, WHILE THE TOKEN WAS IN FLIGHT: nothing is shown, and a
        // session the service did open is discarded.
        guard phase == .minting else {
            if case let .success(credential) = answer {
                await discard(credential)
            }
            return
        }
        switch answer {
        case let .success(credential):
            self.credential = credential
            micMode = credential.micMode
            phase = .notice(credential)
        // ⚠️ THE ALLOWANCE AND CAPACITY REFUSALS ARE THE SERVICE'S OWN SENTENCES, in the
        // app's language through the core's error table; the text console keeps working.
        case let .failure(error) where error.code == ApiErrorCode.hqVoiceAllowanceReached
            || error.code == ApiErrorCode.hqVoiceBusy:
            phase = .ended(.refused(FailureText.from(error).message))
        case let .failure(error):
            phase = .ended(.failed(FailureText.from(error).message))
        }
    }

    /// The member declined the notice: nothing is joined, and the session is discarded.
    func cancelNotice() async {
        guard case let .notice(credential) = phase else { return }
        self.credential = nil
        phase = .idle
        await discard(credential)
    }

    /// The member said Start on the notice: claim the audio, join, open the microphone only
    /// for an open mode.
    func begin() async {
        guard case let .notice(credential) = phase, let key = credential.e2ee?.key else { return }
        guard !callStack.hasLiveCall, !callStack.hasLiveRoom else {
            phase = .ended(.busy)
            await discard(credential)
            return
        }
        phase = .connecting
        callStack.claimRoom(self)
        let engine = makeEngine(key)
        self.engine = engine
        listen(to: engine)
        do {
            try await engine.connect(url: credential.url, token: credential.token)
        } catch {
            await finish(.failed(VoiceFailure.joinFailed))
            return
        }
        guard phase == .connecting else { return }
        phase = .live
        micWanted = micMode == .open
        isMicrophoneOn = micWanted ? await engine.setMicrophone(enabled: true) : false
        startTimer()
        report(place)
    }

    // MARK: - While live

    /// Push-to-talk: the microphone is open only while held.
    func holdToTalk(_ held: Bool) async {
        guard phase == .live, micMode == .push else { return }
        await setMicrophone(held)
    }

    /// An open microphone's mute switch.
    func toggleMute() async {
        guard phase == .live, micMode == .open else { return }
        await setMicrophone(!micWanted)
    }

    /// ⛔ SERIALIZED, AND A REQUEST OVERTAKEN BY A NEWER ONE IS SKIPPED. Opening the microphone
    /// publishes a track over the network, so a quick press and release could otherwise finish
    /// out of order and leave the microphone open after the button was let go.
    private func setMicrophone(_ wanted: Bool) async {
        micWanted = wanted
        let previous = microphoneChange
        let change = Task { [weak self] in
            await previous?.value
            guard let self, micWanted == wanted, phase == .live, let engine else { return }
            let applied = await engine.setMicrophone(enabled: wanted)
            if micWanted == wanted, phase == .live {
                isMicrophoneOn = applied
            }
        }
        microphoneChange = change
        await change.value
    }

    /// Reports the screen to the agent, on each shell navigation. Fire and forget: the next
    /// report replaces a lost one. ⚠️ Remembered before the join, so the first report says
    /// where the member is rather than assuming the HQ screen.
    func report(_ place: HQVoicePlace) {
        self.place = place
        guard phase == .live, let roomName = credential?.roomName else { return }
        screenVersion += 1
        let screen = HQVoiceScreen(version: screenVersion, page: place.page, selected: place.selected)
        let hq = hq
        let workspaceId = workspaceId
        Task { _ = await hq.reportVoiceScreen(workspaceId: workspaceId, roomName: roomName, screen: screen) }
    }

    func confirm(_ card: ProposalCard) async {
        guard canConfirm, let index = proposals.firstIndex(where: { $0.id == card.id }) else { return }
        proposals[index].isWorking = true
        let result = await hq.confirm(workspaceId: workspaceId, voiceProposal: card.proposal)
        guard let index = proposals.firstIndex(where: { $0.id == card.id }) else { return }
        proposals[index].isWorking = false
        proposals[index].outcome = (try? result.get())?.executed == true ? .applied : .failed
    }

    func cancel(_ card: ProposalCard) async {
        guard let index = proposals.firstIndex(where: { $0.id == card.id }) else { return }
        proposals[index].isWorking = true
        let result = await hq.cancel(workspaceId: workspaceId, proposalId: card.proposal.proposalId)
        guard let index = proposals.firstIndex(where: { $0.id == card.id }) else { return }
        proposals[index].isWorking = false
        if case .success = result {
            proposals[index].outcome = .cancelled
        }
    }

    // MARK: - Ending

    /// The member stopped the session.
    func stop() async {
        guard isActive else { return }
        if case .notice = phase {
            await cancelNotice()
            return
        }
        await finish(.byMember)
    }

    /// ⛔ A DISTRICT CALL, A SIGN-OUT OR A WORKSPACE CHANGE ENDS IT. See ``CallStack/endRoom(_:)``.
    func yieldAudio(_ reason: RoomAudioYield) async {
        await finish(reason == .telephoneCall ? .callArrived : .byMember, releasing: false)
    }

    /// ⛔ AT THE RING, NOT THE ANSWER: see ``RoomAudio/yieldsAtRing``.
    var yieldsAtRing: Bool {
        true
    }

    /// ⚠️ THE ROOM CLOSING ON ITS OWN (``EndReason/disconnected``) CALLS NOTHING: the service
    /// ended it.
    private func finish(_ reason: EndReason, releasing: Bool = true) async {
        guard isActive else { return }
        let wasLive = phase == .live
        let credential = credential
        timer?.cancel()
        timer = nil
        listening?.cancel()
        listening = nil
        let engine = engine
        self.engine = nil
        isMicrophoneOn = false
        micWanted = false
        agentState = nil
        if releasing {
            callStack.releaseRoom(self)
        }
        phase = .ended(reason)
        await engine?.disconnect()
        guard let credential, reason != .disconnected else { return }
        if wasLive {
            _ = await hq.endVoice(workspaceId: workspaceId, sessionId: credential.sessionId)
        } else {
            await discard(credential)
        }
    }

    /// A session that never went live: the notice declined, or the join failed or was refused.
    private func discard(_ credential: HQVoiceTokenResponse) async {
        _ = await hq.discardVoice(workspaceId: workspaceId, sessionId: credential.sessionId)
    }

    private func reset() {
        segments = []
        proposals = []
        agentState = nil
        screenVersion = 0
    }

    private func startTimer() {
        let sleep = sleep
        timer = Task { [weak self] in
            do {
                try await sleep(HQVoice.sessionSeconds)
            } catch {
                return
            }
            await self?.finish(.timedOut)
        }
    }

    private func listen(to engine: any HQVoiceEngine) {
        let events = engine.events
        listening = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await handle(event)
            }
        }
    }

    private func handle(_ event: HQVoiceEngineEvent) async {
        switch event {
        case .connected:
            break
        case .disconnected:
            if phase == .live {
                await finish(.disconnected)
            }
        // ⚠️ FINAL SEGMENTS ONLY: an interim one would be read out by VoiceOver and then replaced.
        case let .transcript(segment):
            guard segment.isFinal else { return }
            if let index = segments.firstIndex(where: { $0.id == segment.id }) {
                segments[index] = segment
            } else {
                segments.append(segment)
            }
        case let .agentState(state):
            agentState = state
        case let .packet(.proposal(proposal)):
            guard !proposals.contains(where: { $0.id == proposal.proposalId }) else { return }
            proposals.append(ProposalCard(proposal: proposal))
        case let .packet(.resolved(resolution)):
            guard let index = proposals.firstIndex(where: { $0.id == resolution.proposalId }) else { return }
            proposals[index].outcome = resolution.status
            proposals[index].isWorking = false
        }
    }
}

/// The session's own sentences for a failure the service did not word.
enum VoiceFailure {
    static var joinFailed: String {
        HQCopy.voiceJoinFailed
    }
}
