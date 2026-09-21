import AVFoundation
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import LiveKit
import Observation

/// One live `meet_` room, for as long as its destination exists.
///
/// ⛔ THE JOIN IS A DELIBERATE PRESS AND IS NEVER AN EFFECT, WHICH IS THE ONE RULE ON
/// THIS SCREEN THAT IS NOT NEGOTIABLE AND IS ALSO WHERE THIS CLIENT DIVERGES FROM
/// ANDROID. `Route.activeRoom` is an ordinary navigation destination, so it is
/// RESTORED FROM THE PATH after process death; the Kotlin screen joins from its
/// permission-launcher effect, which on iOS would mean a killed phone coming back and
/// silently re-entering a room, re-dispatching its Companion and putting a live
/// microphone in somebody's pocket. `Route.dialer`'s own ⛔ refuses to have an in-call
/// route for exactly this reason, and rooms cannot take that escape because the room
/// name has to survive in the destination. So the screen opens on ``RoomPhase/idle``
/// with a Join control, and nothing connects until it is pressed.
///
/// ⛔ IT OWNS AT MOST ONE ``RoomEngine`` AT A TIME, AND A NEW ONE PER JOIN. The engine
/// holds a live socket and the device's audio route, and a LiveKit `Room` does not
/// support a second `connect` after it has disconnected — so a rejoin drops the dead
/// engine and builds a fresh one rather than re-pointing the old one. ⚠️ The
/// destination is keyed on the room NAME, so navigating to a DIFFERENT room builds a
/// different model.
///
/// ⛔ AND IT REFUSES TO JOIN WHILE A TELEPHONE CALL IS LIVE. One process owns one
/// `AVAudioSession`: the softphone's ``AudioSessionCoordinator`` configures it while
/// CallKit activates it, and ``RoomEngine/connect(url:token:)`` hands the session back
/// to the SDK's own automation. Both are correct for their own case and they cannot
/// both be right at once, so the overlap is prevented rather than arbitrated in the
/// audio layer.
///
/// ⛔ AND THE EXCLUSION IS MUTUAL. The predicate is ``CallStack/hasLiveCall``, the
/// claim both call models use on each other, which is true for the WHOLE of a call;
/// ``CallStack/engine`` is built at MEDIA time and would miss the 30-second inbound
/// ring and the outbound window between the Call tap and the dial being accepted,
/// while the copy promises "There is a call on this device. End it before joining a
/// room." And the call path has to know about rooms, or nothing refuses, mutes or
/// leaves a ROOM when a call starts: an operator could answer a customer while a
/// meeting held a live microphone, and the meeting would hear the whole private call
/// while the caller heard the meeting. So this model takes
/// ``CallStack/claimRoom(_:)`` for the length of a join and conforms to ``RoomAudio``
/// so the call path can take the audio back.
///
/// ⛔ THAT CLAIM IS ALSO THIS OBJECT'S LIFETIME, EXACTLY AS ``DialerModel``'S IS. The
/// container holds it while a room is live, so a screen destroyed by a sign-out or a
/// workspace switch cannot strand a publishing microphone with no owner. Nothing else
/// would tear it down: ``leave()`` is the only other caller of `disconnect()`, and
/// there is no `deinit` (a `@MainActor` class's `deinit` is nonisolated under Swift 6
/// and could not touch these properties).
///
/// ⛔ ``canPublish`` IS THE ROLE'S ANSWER AND IT FAILS CLOSED. `role != nil && role
/// != .viewer`, never `role != .viewer` on its own: a nil role is what
/// `WorkspaceRole.fromWire` returns for a value the route could not parse, and
/// `nil != .viewer` is TRUE, so the shorter expression would hand an UNKNOWN role
/// publish rights. ⚠️ It is an affordance rather than an enforcement: a viewer's token
/// carries `canPublish:false` and the media server refuses either track whatever this
/// client believes. Disabling the controls avoids offering an action that cannot work.
@MainActor
@Observable
final class ActiveRoomModel: RoomAudio {
    private(set) var phase: RoomPhase = .idle

    /// ⛔ HUMANS ONLY. The Companion publishes no media, so leaving it in the grid
    /// draws a blank muted tile in the middle of a meeting. Removing it silently
    /// would be worse: it is listening and writing minutes, and a person in the room
    /// is entitled to know that, so it is surfaced as ``companionPresent``.
    private(set) var tiles: [RoomParticipantSnapshot] = []

    /// ⚠️ SURFACED AS "taking notes", NEVER HIDDEN. See ``tiles``.
    private(set) var companionPresent = false

    /// ⚠️ THE LOCAL CAMERA TRACK, held so the self tile can render it. nil whenever
    /// nothing is publishing, which is the state the room is joined in.
    private(set) var localVideo: VideoTrack?

    private(set) var micEnabled = false

    private(set) var cameraEnabled = false

    /// ⚠️ WHAT WAS ASKED FOR, NOT WHAT THE DEVICE DID: the SDK's preference, which its
    /// automation routes by. Read from the engine at each join, because the SDK's own
    /// default is the speaker and it is process-wide, so a literal here would disagree.
    private(set) var speakerOn = false

    /// ⚠️ THE JOIN ITSELF FAILING, SHOWN INSTEAD OF THE ROOM. Distinct from
    /// ``phase``: the engine never connected, so its own state is still idle and
    /// would immediately overwrite anything set there.
    private(set) var joinFailure: FailureText?

    /// ⚠️ A CAMERA FLIP THAT WAS ASKED FOR AND REFUSED, WHICH IS NOT THE SAME AS ONE
    /// THAT HAD NOTHING TO DO. ``RoomEngine/flipCamera()`` answers true for the second
    /// case, so this is only ever true when a camera and a capturer both existed and
    /// the SDK still said no.
    ///
    /// ⛔ RENDERED THROUGH ``RoomNotice``, NEVER ``RoomJoinFailure``. The meeting is
    /// unaffected and exactly one control is; a danger-toned "Could not join" over a
    /// live room would be a worse lie than the silence this replaces. ⚠️ It is a
    /// BOOLEAN rather than a message because the sentence belongs in ``RoomsCopy``
    /// with every other sentence this screen says.
    private(set) var flipFailed = false

    /// An absolute, shareable guest link, or nil.
    ///
    /// ⛔ NULL FOR A VIEWER BY SERVER DECISION, AND THIS CLIENT MUST NOT SYNTHESISE
    /// ONE. The invite is a transferable twelve-hour capability that grants PUBLISH
    /// rights to whoever holds it, so the route mints it only for a non-viewer, and
    /// `guestPath` is assembled server-side because the signature is computed over
    /// that exact encoding. A link rebuilt from the room name is one
    /// `/api/meet/token` will refuse, and it would look, to the person sharing it,
    /// exactly like a working invitation until their guest could not join.
    private(set) var guestLink: URL?

    private(set) var permissions = RoomPermissions()

    /// ⛔ See the ⛔ on this type. Fails closed on an unparseable role.
    let canPublish: Bool

    let roomName: RoomName

    /// ⚠️ The human half of the name. `meet_<uuid>_standup` is not a title.
    var displayName: String {
        RoomName.displayName(roomName.value)
    }

    private let repository: RoomsRepository
    private let callStack: CallStack
    private let webOrigin: URL

    private var engine: RoomEngine?
    private var pump: Task<Void, Never>?

    /// The operator has left, deliberately and for good.
    ///
    /// ⛔ ONE-WAY, AND IT IS WHAT MAKES "LEAVE DISCONNECTS EXACTLY ONCE" TRUE: a second
    /// press finds it set and does nothing.
    ///
    /// ⛔ POPPING THE DESTINATION DISCONNECTS NOTHING BY ITSELF. There is no `deinit`,
    /// no `onDisappear` and no `scenePhase` hook; the teardown runs through
    /// ``CallStack``, which holds this object while the room is live and ends it
    /// explicitly. ⚠️ ``yieldAudio(_:)`` deliberately does NOT set this: the operator
    /// did not choose that ending and is offered the room back.
    private var released = false

    /// - Parameter webOrigin: ⚠️ DEFAULTED TO THE PRODUCTION ORIGIN RATHER THAN READ
    ///   OFF THE CONTAINER. It is the origin a `guestPath` is joined onto and nothing
    ///   else; the credential itself comes from the container's client.
    init(
        container: AppContainer,
        roomName: RoomName,
        role: WorkspaceRole?,
        webOrigin: URL = ApiClient.productionBaseURL
    ) {
        canPublish = role != nil && role != .viewer
        self.roomName = roomName
        repository = container.rooms
        callStack = container.callStack
        self.webOrigin = webOrigin
    }

    // MARK: - Joining

    /// Ask the OS for the microphone and the camera, then join.
    ///
    /// ⛔ THE ONLY ENTRY POINT TO THE CONNECT, AND IT IS REACHED FROM A BUTTON. See
    /// the ⛔ on this type for why it is not a `.task`.
    ///
    /// ⛔ NEITHER DENIAL IS FATAL. Both refusals still leave a usable meeting, so the
    /// join happens either way and what changes is which controls are enabled and
    /// what the screen says about why. A denied camera is audio-only attendance; a
    /// denied microphone is listen-only attendance, which is exactly the seat a
    /// viewer is given by the server regardless.
    ///
    /// ⚠️ IDEMPOTENT. A second press while a join is in flight, or once one has
    /// landed, would tear down the media it just established.
    ///
    /// ⚠️ IT IS ALSO THE REJOIN, WHICH IS WHY THE GUARD IS ``RoomPhase/canJoin``
    /// RATHER THAN `case .idle`. Every dead-but-not-left phase may run it again; the
    /// dead engine is dropped first, because a LiveKit `Room` does not support a
    /// second `connect` after it has disconnected.
    func join() async {
        guard phase.canJoin, !released else { return }

        // ⛔ THE AUDIO SESSION HAS ONE OWNER PER PROCESS, AND THIS IS THE PREDICATE
        // THAT IS TRUE FOR THE WHOLE OF A CALL. `callStack.engine` exists only from
        // MEDIA time, so testing it would permit a join throughout the inbound ring
        // and the whole outbound dial window. See the ⛔ on ``CallStack/hasLiveCall``.
        guard !callStack.hasLiveCall else {
            joinFailure = RoomsCopy.busyWithCall
            return
        }
        // ⛔ AND ONE ROOM, because the claim below is what holds this object alive: a
        // second claim would drop the first model's only reference and strand its
        // engine, which is the leak the claim exists to close.
        guard !callStack.hasLiveRoom else {
            joinFailure = RoomsCopy.busyWithRoom
            return
        }

        await dropEngine()
        phase = .joining
        joinFailure = nil
        // ⛔ CLAIMED BEFORE THE PERMISSIONS AND THE TOKEN READ, NOT AFTER THE CONNECT.
        // Both of those await, and a dial tapped across either would otherwise find no
        // room and be allowed. ``release()`` gives it back on every exit.
        callStack.claimRoom(self)
        await requestPermissions()

        switch await repository.token(roomName: roomName) {
        case let .success(credential):
            await connect(with: credential)
        case let .failure(error):
            // ⛔ BACK TO `idle`, NOT `failed`. The engine never connected, so there is
            // nothing to report a connection state about, and the reason the user
            // needs is the API failure. Leaving this on `joining` would render a
            // spinner over a join that will never happen.
            phase = .idle
            joinFailure = FailureText.from(error)
            callStack.releaseRoom(self)
        }
    }

    /// ⚠️ ASKED FOR SEPARATELY AND IN ORDER, because the two answers are not one
    /// outcome. `AVCaptureDevice.requestAccess` returns the current grant immediately
    /// when it has already been answered, so this is one path rather than two.
    private func requestPermissions() async {
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        let camera = await AVCaptureDevice.requestAccess(for: .video)
        permissions = RoomPermissions(
            requested: true,
            microphoneGranted: microphone,
            cameraGranted: camera
        )
    }

    private func connect(with credential: RoomTokenResponse) async {
        // ⚠️ NULL FOR A VIEWER, BY SERVER DECISION. Never synthesised.
        guestLink = credential.guestPath.flatMap { URL(string: $0, relativeTo: webOrigin)?.absoluteURL }

        // ⛔ A BLANK KEY IS NOT "no encryption" AND MUST NOT BE FORWARDED. It would
        // derive a real AES key that nobody else in the room derives, so the join
        // would succeed and every track would be noise, which reads as a media fault
        // rather than a key fault. nil joins unencrypted, which is the honest answer
        // when the server sent no usable key.
        let key = credential.e2ee?.key.trimmingCharacters(in: .whitespacesAndNewlines)
        let engine = RoomEngine(e2eeKey: (key?.isEmpty ?? true) ? nil : key)
        self.engine = engine
        speakerOn = engine.isSpeakerPreferred
        // ⛔ THE LOOP BREAKS WHEN THIS MODEL IS GONE, IT DOES NOT MERELY SKIP. The
        // stream is deliberately never finished (`LiveKitCallEngine` records the same
        // rule: `disconnect()` is not the end of the events, since the SDK reports the
        // reason afterwards), so a `self?.apply` that simply did nothing would leave a
        // task holding this engine, and its socket, for the life of the process.
        //
        // ⛔ AND IT CAPTURES THE STREAM RATHER THAN THE ENGINE. `engine.events` inside
        // the closure would capture `engine` STRONGLY — only `self` is weak — so the
        // break above would free the model and not the thing holding the microphone:
        // the `RoomEngine`, its `Room` and its published tracks would outlive
        // everything with nothing left to call `disconnect()`. An `AsyncStream` is a
        // value that does not retain its producer, so hoisting it is what prevents
        // that. ``DialerModel/startEngine()`` has the same shape.
        //
        // ⚠️ `Task {}` INSIDE A `@MainActor` METHOD INHERITS THAT ISOLATION, which is
        // what lets the reducer below be an ordinary synchronous call and what keeps
        // the SDK's video tracks on the actor that renders them.
        let events = engine.events
        pump = Task { [weak self] in
            for await event in events {
                guard let self else { break }
                apply(event)
            }
        }

        do {
            try await engine.connect(url: credential.url, token: credential.token)
        } catch {
            // ⚠️ The engine has already yielded `.failed` and rethrown; this only
            // records that the throw was seen. Letting it escape would crash the
            // process over a network condition.
            phase = .failed(message: error.localizedDescription)
            // ⛔ THE CLAIM GOES BACK ON A FAILED JOIN. Holding it would leave the whole
            // app believing a room owned the audio and refusing every later dial.
            callStack.releaseRoom(self)
            return
        }

        refreshRoster()
        // ⛔ MICROPHONE ON, CAMERA OFF, AND THE ASYMMETRY IS DELIBERATE. Joining muted
        // is a well-known way to hold a meeting in which nobody realises they are
        // inaudible; joining with the camera live is a well-known way to be seen
        // before you meant to be. Granting the camera permission is consent to USE
        // it, not consent to be on it. Both respect `canPublish`, because a viewer's
        // token would have the server refuse either.
        guard canPublish, permissions.microphoneGranted else { return }
        micEnabled = await engine.setMicrophone(enabled: true)
    }

    // MARK: - The controls

    /// ⚠️ A NO-OP WITHOUT PUBLISH RIGHTS OR THE PERMISSION, rather than an attempt
    /// that fails. The media server would refuse a viewer outright, and the OS would
    /// hand an unpermitted engine a silent track, which looks like a working
    /// microphone to everyone except the people who cannot hear it.
    func toggleMicrophone() async {
        guard canPublish, permissions.microphoneGranted else { return }
        guard let engine else { return }
        micEnabled = await engine.setMicrophone(enabled: !micEnabled)
    }

    /// ⚠️ Same gating as ``toggleMicrophone()``, against the camera permission.
    func toggleCamera() async {
        guard canPublish, permissions.cameraGranted else { return }
        guard let engine else { return }
        cameraEnabled = await engine.setCamera(enabled: !cameraEnabled)
        refreshRoster()
    }

    /// ⚠️ ONLY WHILE THE CAMERA IS ON. Flipping a camera that is not publishing does
    /// nothing visible, so the control would report success for an action with no
    /// effect.
    ///
    /// ⛔ AND A REFUSAL IS SAID OUT LOUD RATHER THAN SWALLOWED.
    /// "Never render a failure as an absence" is this client's own rule
    /// and a button that does nothing is precisely the absence: the operator presses
    /// it, the picture does not change, and nothing anywhere says why. ⚠️ The success
    /// path CLEARS the notice, so a flip that works after one that did not takes the
    /// sentence back off the screen.
    func flipCamera() async {
        guard cameraEnabled else { return }
        guard let engine else { return }
        let flipped = await engine.flipCamera()
        flipFailed = !flipped
    }

    func toggleSpeaker() {
        speakerOn.toggle()
        engine?.setSpeakerphone(speakerOn)
    }

    // MARK: - Leaving

    /// Leave the room.
    ///
    /// ⛔ THE DISCONNECT IS AWAITED BEFORE THE CALLER POPS. Popping first would tear
    /// this model down and route the teardown through the path that exists for the
    /// case where nobody pressed anything, which would make the ordinary exit depend
    /// on the emergency one. ⚠️ Kotlin needs a scope that outlives `onCleared` for
    /// this; here the caller simply awaits.
    func leave() async {
        guard !released else { return }
        released = true
        await dropEngine()
        phase = .left
    }

    /// Give this device's audio up because something else needs it.
    ///
    /// ⛔ THE ROOM IS LEFT, NOT MUTED, AND THE OPERATOR IS TOLD WHICH THING TOOK IT.
    /// ``RoomAudioYield`` carries the argument for both halves; the short version is
    /// that muting stops the leak in one direction only and settles nothing about the
    /// two owners of one `AVAudioSession`.
    ///
    /// ⛔ ``released`` IS NOT SET. This is not the operator leaving, so the room is
    /// offered back — see ``RoomPhase/canJoin``.
    ///
    /// ⚠️ THE CLAIM IS HANDED BACK EVEN THOUGH ``CallStack/endRoom(_:)`` HAS ALREADY
    /// DROPPED IT. That call is identity-checked and finds nothing, which is what makes
    /// this safe to reach from anywhere; without it a room that yielded for a reason
    /// nobody routed through `endRoom` would hold the claim forever.
    func yieldAudio(_ reason: RoomAudioYield) async {
        guard !released else { return }
        await dropEngine()
        phase = .yielded(reason)
    }

    /// Stop the pump, disconnect, and put the screen back to a state with no media.
    ///
    /// ⛔ THE PUMP IS CANCELLED BEFORE THE DISCONNECT, WHICH IS WHAT KEEPS THE PHASE
    /// THE CALLER'S TO SET. The SDK reports its disconnect reason AFTER
    /// `disconnect()` returns, so a live pump would deliver a `.disconnected` and
    /// overwrite `left` or `yielded` with `droppedRemotely` a moment later.
    ///
    /// ⚠️ IDEMPOTENT AND SAFE WITH NO ENGINE: `RoomEngine/disconnect()` absorbs a room
    /// that has already gone, and the optional chain absorbs there never having been
    /// one.
    private func dropEngine() async {
        pump?.cancel()
        pump = nil
        await engine?.disconnect()
        engine = nil
        callStack.releaseRoom(self)
        localVideo = nil
        micEnabled = false
        cameraEnabled = false
        tiles = []
        companionPresent = false
        // ⚠️ CLEARED HERE TOO, BECAUSE THE PUMP IS ALREADY CANCELLED ABOVE and the
        // `.cameraChanged(false)` that would otherwise do it never arrives. Without
        // this the notice survives onto the "You have left this room" screen, where it
        // is about a control that is no longer on screen.
        flipFailed = false
    }

    // MARK: - Reducing

    private func apply(_ event: RoomEngineEvent) {
        switch event {
        case .connected:
            // ⚠️ ALSO THE RECOVERY SIGNAL. Without this a quick reconnect would leave
            // the banner up for the rest of a meeting that had already recovered.
            phase = .connected
            refreshRoster()
        case .reconnecting:
            // ⛔ A BANNER OVER A LIVE MEETING, NEVER A FAILURE. The tiles stay.
            phase = .reconnecting
        case let .disconnected(reason):
            // ⛔ NEVER `left`, NOT EVEN FOR A nil REASON.
            // ``leave()`` cancels the pump before it disconnects and sets the phase
            // itself, so this branch is reachable ONLY for a disconnect the operator
            // did not cause — removed by the SFU, room deleted, token expired, a
            // duplicate identity evicting this session — and none of those is
            // "You have left this room." The two call reducers next door
            // map the identical event to ``CallEndReason/remoteEnded(reason:)``.
            // ⚠️ ``released`` IS CHECKED ANYWAY, as a latch for the ordering rather
            // than for the meaning: if a cancel ever loses a race with the SDK's own
            // report, the operator's own act still wins.
            phase = released ? .left : .droppedRemotely(reason: reason)
            localVideo = nil
            callStack.releaseRoom(self)
        case .rosterChanged:
            refreshRoster()
        case .speakersChanged:
            // ⛔ IGNORED HERE, ON PURPOSE, AND NOT FOLDED INTO ``rosterChanged``. The SFU
            // publishes speaker updates for the whole of a meeting; this grid draws no
            // speaking ring and no level, so reacting would rebuild every tile several
            // times a second to change nothing. The persona preview is the reader that
            // case exists for.
            break
        case let .microphoneChanged(enabled):
            micEnabled = enabled
        case let .cameraChanged(enabled):
            cameraEnabled = enabled
            // ⚠️ A COMPLAINT ABOUT SWAPPING CAMERAS IS STALE THE MOMENT THERE IS NO
            // CAMERA TO SWAP, and this is the SDK's own signal rather than the
            // toggle's, so it covers a deliberate stop and a server-side unpublish
            // alike. The flip control is disabled in that state anyway; what this
            // prevents is the sentence outliving the thing it was about.
            if !enabled {
                flipFailed = false
            }
            refreshRoster()
        case let .failed(message):
            phase = .failed(message: message)
            localVideo = nil
            // ⛔ THE CLAIM GOES BACK ON A LOST SESSION TOO. A room that is not there
            // any more must not go on refusing this device's next telephone call.
            callStack.releaseRoom(self)
        }
    }

    /// ⛔ THE COMPANION IS SPLIT OUT IN THE SAME WRITE THE GRID IS BUILT IN, so the
    /// tiles and the chip can never disagree about whether it is in the room.
    private func refreshRoster() {
        guard let engine else { return }
        let everyone = engine.roster()
        tiles = everyone.filter { !ActiveRoomModel.isCompanion($0) }
        companionPresent = everyone.contains(where: ActiveRoomModel.isCompanion)
        localVideo = engine.localCameraTrack()
    }

    /// Is this participant the note-taking Companion rather than a person?
    ///
    /// ⛔ THE SAME TWO TESTS THE WEB APPLIES, IN THE SAME ORDER, AND THE DUPLICATION
    /// IS THE POINT. Getting this wrong on one platform and not the other produces a
    /// blank muted tile that only phone users see. The KIND is the real test (the
    /// voice agent joins through the Agents framework with the agent kind); the
    /// prefix is a retired browser-side signalling participant that nothing mints any
    /// more, kept because a room built before the metadata cutover could still
    /// contain one.
    private static func isCompanion(_ participant: RoomParticipantSnapshot) -> Bool {
        participant.isAgent || participant.identity.hasPrefix(retiredCompanionPrefix)
    }

    private static let retiredCompanionPrefix = "ai-companion-"
}
