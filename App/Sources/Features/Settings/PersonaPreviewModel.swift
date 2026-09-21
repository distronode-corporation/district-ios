import AVFoundation
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import Observation

/// One persona audition: a real, billed call to this workspace's own voice agent,
/// answering as the form on screen describes it.
///
/// ⛔ NOTHING HERE IS A DRY RUN, AND EVERY RULE IN THIS TYPE FOLLOWS FROM THAT. The
/// token invites the agent into a `preview_<workspaceId>_<uuid>` room on the
/// workspace's own pipeline and its own media node, where it answers with speech
/// recognition, a model and speech synthesis exactly as it would on a telephone call.
/// The route is capped at 10/min per WORKSPACE, it is not idempotent, and the spend
/// lands downstream in the agent rather than in the handler — so a failure is FINAL
/// here (a button, never a retry), a second tap while one is running is dropped, and
/// the control stays disabled for a few seconds after one ends.
///
/// ⛔ IT CLAIMS THE DEVICE'S AUDIO THROUGH ``CallStack`` AND CONFORMS TO ``RoomAudio``,
/// WHICH IS THE WHOLE OF ITS ARBITRATION. One process owns one `AVAudioSession`: the
/// softphone's ``AudioSessionCoordinator`` configures it while CallKit activates it,
/// and ``RoomEngine/connect(url:token:)`` hands it back to the SDK's own automation.
/// Both are correct for their own case and cannot both be right at once. So a preview
/// is REFUSED while a call or a room is live, and an arriving call ENDS the preview —
/// `CallStack.beginCall()` awaits `endRoom(.telephoneCall)` before it builds the call's
/// engine, which reaches ``yieldAudio(_:)`` here. Without the claim, the refusal would
/// point one way only, which is the shape that makes a private customer call audible
/// in a meeting.
///
/// ⛔ IT NEVER REACHES ``CallKitBridge``. An audition is not a telephone call and must
/// not appear in the system's call list, be resumable from it, or count against the
/// one-call-at-a-time the provider declares to the OS.
///
/// ⚠️ THE CLAIM IS ALSO THIS OBJECT'S LIFETIME. The sheet can be dismissed, and a
/// workspace switch or a sign-out can destroy the screen outright; the claim is what
/// keeps a publishing microphone owned by something rather than stranded. The other
/// half of that bargain is that every exit path ends the session — see ``end()``,
/// ``yieldAudio(_:)`` and the view's `onDisappear`.
@MainActor
@Observable
final class PersonaPreviewModel: RoomAudio {
    private(set) var phase: PersonaPreviewPhase = .idle

    /// ⚠️ THE MINT FAILING, HELD SEPARATELY FROM ``phase``. The engine never connected,
    /// so its own state is still idle and would overwrite anything set there.
    private(set) var failure: FailureText?

    /// ⚠️ WHAT THE SDK ACCEPTED, not what was asked for.
    private(set) var micEnabled = false

    /// ⚠️ SAID OUT LOUD RATHER THAN LEFT AS SILENCE. A denied microphone still leaves a
    /// usable audition — the agent greets and can be heard — but it is fatal to the
    /// point of one, so the session goes ahead and the screen says why nothing is being
    /// heard back.
    private(set) var microphoneDenied = false

    /// Whether the agent has joined the room yet.
    private(set) var agentPresent = false

    /// How loud the agent is, 0 to 1.
    ///
    /// ⚠️ THE ANSWER TO "is it actually saying anything", which on an audition is the
    /// question. It moves on ``RoomEngineEvent/speakersChanged``, which the SFU
    /// publishes continuously, and is reported as text as well as a bar.
    private(set) var level: Double = 0

    /// ⛔ THE FEW SECONDS AFTER A SESSION, DURING WHICH ANOTHER MAY NOT BE STARTED. The
    /// route's 10/min ceiling is the only thing bounding a loop of billed sessions, and
    /// a disabled button for a moment is a cheaper guard than the ceiling.
    private(set) var cooling = false

    /// ⚠️ A TEST SEAM AND NOTHING ELSE. The cooldown is a detached sleep, so without a
    /// handle a test could only assert it by waiting in real time.
    private(set) var cooldownTask: Task<Void, Never>?

    /// ⛔ NOT MERELY `!phase.isRunning`. A preview may not start while a telephone call
    /// or a room owns the audio, and may not start during the cooldown.
    var canStart: Bool {
        !phase.isRunning && !cooling && !callStack.hasLiveCall && !callStack.hasLiveRoom
    }

    /// ⚠️ WHY THE BUTTON IS DISABLED, so the refusal is a sentence rather than a
    /// greyed-out control with no explanation.
    var refusal: String? {
        if callStack.hasLiveCall {
            return SettingsCopy.previewBusyCall
        }
        if callStack.hasLiveRoom, !phase.isRunning {
            return SettingsCopy.previewBusyRoom
        }
        if cooling {
            return SettingsCopy.previewCooldown
        }
        return nil
    }

    private let workspaces: WorkspaceRepository
    private let workspaceId: String
    private let form: PersonaPreviewForm
    private let callStack: CallStack
    private let makeEngine: @Sendable (String?) -> any PersonaPreviewEngine
    private let cooldown: @Sendable () async -> Void
    private let requestMicrophone: @Sendable () async -> Bool

    private var engine: (any PersonaPreviewEngine)?
    private var pump: Task<Void, Never>?

    /// - Parameter makeEngine: built per session, taking the room's passphrase. ⛔ The
    ///   key is handed to the SDK VERBATIM and never base64-decoded: every LiveKit SDK
    ///   UTF-8-encodes this string and runs PBKDF2 over those ASCII bytes, so decoding
    ///   it selects a different key and the failure is not an error — both sides join
    ///   and every track is undecryptable noise.
    /// - Parameter cooldown: how long the Start control stays disabled after a session.
    /// - Parameter requestMicrophone: the OS permission prompt, injected so the state
    ///   machine can be driven without one.
    init(
        workspaces: WorkspaceRepository,
        workspaceId: String,
        form: PersonaPreviewForm,
        callStack: CallStack,
        makeEngine: @escaping @Sendable (String?) -> any PersonaPreviewEngine = { RoomEngine(e2eeKey: $0) },
        cooldown: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(5)) },
        requestMicrophone: @escaping @Sendable () async -> Bool = {
            await AVCaptureDevice.requestAccess(for: .audio)
        }
    ) {
        self.workspaces = workspaces
        self.workspaceId = workspaceId
        self.form = form
        self.callStack = callStack
        self.makeEngine = makeEngine
        self.cooldown = cooldown
        self.requestMicrophone = requestMicrophone
    }

    @MainActor
    convenience init(container: AppContainer, workspaceId: String, form: PersonaPreviewForm) {
        self.init(
            workspaces: container.workspaces,
            workspaceId: workspaceId,
            form: form,
            callStack: container.callStack
        )
    }

    // MARK: - Starting

    /// Mint a credential for the form on screen and join the room it names.
    ///
    /// ⛔ THE ONLY ENTRY POINT, AND IT IS REACHED FROM A BUTTON. Minting on appear would
    /// charge for a screen somebody opened to read.
    ///
    /// ⛔ A FAILED MINT IS FINAL. The route is not idempotent and each token starts a
    /// billed session, so nothing here retries; the operator is left on a button.
    ///
    /// ⚠️ IDEMPOTENT. A second press while one is running would tear down the media it
    /// just established.
    func start() async {
        guard canStart else { return }
        failure = nil
        microphoneDenied = false
        phase = .minting
        // ⛔ CLAIMED BEFORE THE MINT AND THE PERMISSION PROMPT, NOT AFTER THE CONNECT.
        // Both of those await, and a dial or a room join tapped across either would
        // otherwise find nothing holding the audio and be allowed.
        callStack.claimRoom(self)

        switch await workspaces.previewToken(workspaceId: workspaceId, form: form) {
        case let .success(credential):
            await connect(with: credential)
        case let .failure(error):
            phase = .failed
            failure = FailureText.from(error)
            callStack.releaseRoom(self)
            // ⚠️ THE COOLDOWN RUNS ON A REFUSAL TOO, AND THAT IS THE CASE IT MATTERS
            // MOST IN. The commonest refusal here is the route's own 10/min ceiling, and
            // a button that re-arms instantly invites the operator to spend the rest of
            // the minute's slots finding out it is still refused.
            startCooldown()
        }
    }

    private func connect(with credential: PersonaPreviewTokenResponse) async {
        phase = .connecting
        // ⛔ A BLANK KEY IS NOT "no encryption" AND MUST NOT BE FORWARDED: it would
        // derive a real key nobody else in the room derives, so the join would succeed
        // and every track would be noise. ⚠️ AND AN ABSENT KEY HERE IS NOT THE SAME AS
        // ON `calls/token`: a `preview_*` room is always encrypted, so nil means the
        // server failed to derive one rather than "join in the clear".
        let key = credential.e2ee?.key.trimmingCharacters(in: .whitespacesAndNewlines)
        let engine = makeEngine((key?.isEmpty ?? true) ? nil : key)
        self.engine = engine
        // ⛔ IT CAPTURES THE STREAM RATHER THAN THE ENGINE, the leak ``ActiveRoomModel``
        // documents: `engine.events` inside the closure would capture the ENGINE
        // strongly, so a freed model would leave a task holding the microphone for the
        // life of the process. An `AsyncStream` is a value that does not retain its
        // producer.
        let events = engine.events
        pump = Task { [weak self] in
            for await event in events {
                guard let self else { break }
                apply(event)
            }
        }

        // ⚠️ ASKED FOR AFTER THE TOKEN AND BEFORE THE CONNECT. A denial is not fatal —
        // see ``microphoneDenied`` — so this never gates the join.
        microphoneDenied = await !requestMicrophone()

        do {
            try await engine.connect(url: credential.url, token: credential.token)
        } catch {
            // ⚠️ The engine has already yielded `.failed` and rethrown; this records
            // that the throw was seen. Letting it escape would crash the process over a
            // network condition.
            phase = .failed
            failure = FailureText(message: error.localizedDescription, action: .none)
            callStack.releaseRoom(self)
            return
        }

        // ⛔ SPEAKER ON AND THE MICROPHONE PUBLISHED, WHICH IS THE OPPOSITE OF A MEETING
        // AND RIGHT HERE. An audition is held at arm's length while somebody watches the
        // form; the earpiece would have them hold the phone to their head to hear a
        // voice they are choosing. And an audition joined muted is an audition of
        // nothing — unlike a meeting, where joining muted is ordinary.
        engine.setSpeakerphone(true)
        guard !microphoneDenied else { return }
        micEnabled = await engine.setMicrophone(enabled: true)
    }

    // MARK: - Ending

    /// Stop the session deliberately.
    ///
    /// ⚠️ SAFE FROM ANY STATE, including one that never started: the sheet's
    /// `onDisappear` calls it unconditionally, because a dismissed screen must not leave
    /// a room publishing.
    func end() async {
        // ⛔ THE TEARDOWN RUNS FROM EVERY STATE AND ONLY THE PHASE IS CONDITIONAL. A
        // session that FAILED mid-call, or was dropped by the server, still holds an
        // engine and a socket — the reducer sets the phase and hands the audio claim
        // back, it does not disconnect — so guarding the whole method on `isRunning`
        // would leave a dismissed sheet with a live `Room` publishing a microphone and
        // nothing able to reach it. `teardown()` is
        // idempotent and cheap with nothing to tear down.
        let wasRunning = phase.isRunning
        await teardown()
        guard wasRunning else { return }
        phase = .ended(.stopped)
        startCooldown()
    }

    /// Give this device's audio up because something else needs it.
    ///
    /// ⛔ THE SESSION IS ENDED, NOT MUTED, AND THE OPERATOR IS TOLD WHICH THING TOOK IT.
    /// ``RoomAudioYield`` carries the argument in full; the short version is that muting
    /// settles nothing about two owners of one `AVAudioSession`, and
    /// `isAutomaticConfigurationEnabled` is process-global.
    func yieldAudio(_ reason: RoomAudioYield) async {
        let wasRunning = phase.isRunning
        await teardown()
        guard wasRunning else { return }
        phase = .ended(.yielded(reason))
        startCooldown()
    }

    /// ⛔ THE PUMP IS CANCELLED BEFORE THE DISCONNECT, which is what keeps the phase the
    /// caller's to set: the SDK reports its disconnect reason AFTER `disconnect()`
    /// returns, so a live pump would overwrite `ended` with a remote drop a moment later.
    private func teardown() async {
        pump?.cancel()
        pump = nil
        await engine?.disconnect()
        engine = nil
        callStack.releaseRoom(self)
        micEnabled = false
        agentPresent = false
        level = 0
    }

    /// ⚠️ THE TASK IS HELD rather than detached and forgotten, so the flag cannot
    /// outlive the object and a test can await it instead of sleeping.
    private func startCooldown() {
        cooling = true
        cooldownTask = Task { [weak self, cooldown] in
            await cooldown()
            self?.cooling = false
        }
    }

    // MARK: - Reducing

    private func apply(_ event: RoomEngineEvent) {
        switch event {
        case .connected:
            // ⚠️ ALSO THE RECOVERY SIGNAL after a reconnect, so it is not only a
            // first-connect event. The roster decides between waiting and live.
            refreshRoster()
        case .reconnecting:
            phase = .reconnecting
        case let .disconnected(reason):
            // ⛔ NEVER `stopped`. ``end()`` cancels the pump before it disconnects and
            // sets the phase itself, so this branch is reachable only for a disconnect
            // the operator did not cause — a token expiring, the agent's room being
            // torn down, a duplicate identity evicting this session.
            endedRemotely(reason: reason)
        case .rosterChanged:
            refreshRoster()
        case .speakersChanged:
            refreshLevel()
        case let .microphoneChanged(enabled):
            micEnabled = enabled
        case .cameraChanged:
            // ⛔ UNREACHABLE AND HANDLED ANYWAY. This path publishes no camera and the
            // agent has none; a `default` here would swallow a future case that mattered.
            break
        case let .failed(message):
            phase = .failed
            failure = FailureText(message: message ?? SettingsCopy.previewDropped, action: .none)
            callStack.releaseRoom(self)
            startCooldown()
        }
    }

    private func endedRemotely(reason: String?) {
        phase = .ended(.droppedRemotely(reason: reason))
        callStack.releaseRoom(self)
        agentPresent = false
        level = 0
        startCooldown()
    }

    /// ⛔ THE AGENT IS IDENTIFIED BY THE SDK'S OWN KIND, never by an identity prefix
    /// alone — the same test ``ActiveRoomModel`` applies, in the same order.
    private func refreshRoster() {
        guard let engine else { return }
        let roster = engine.roster()
        agentPresent = roster.contains { $0.isAgent }
        phase = agentPresent ? .live : .waiting
        refreshLevel(roster)
    }

    private func refreshLevel(_ roster: [RoomParticipantSnapshot]? = nil) {
        guard let engine else { return }
        let people = roster ?? engine.roster()
        // ⚠️ THE LOUDEST REMOTE PARTICIPANT, which in a `preview_*` room is the agent
        // and nobody else. `max` rather than the agent's own level so a room that
        // somehow held a second participant still reports something true.
        level = people.map(\.audioLevel).max() ?? 0
    }
}
