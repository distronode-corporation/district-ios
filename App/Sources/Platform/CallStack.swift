import DistrictCall
import Foundation

/// The platform half of a call, assembled once so no feature has to wire it.
///
/// ⛔ TWO DIFFERENT LIFETIMES LIVE HERE AND THEY ARE NOT NEGOTIABLE, WHICH IS THE
/// WHOLE REASON THIS TYPE EXISTS RATHER THAN A CONSTRUCTOR AT A CALL SITE:
///
///   * `CXProvider` is **one per app**. Apple says so outright, and a second one puts
///     a duplicate entry in the system's own call surfaces and leaks the first. So
///     ``callKit`` and the ``audio`` coordinator it holds live as long as this object.
///   * A LiveKit `Room` is **one per call**. ``CallEngine``'s own ⛔ says why: it holds
///     a live socket and a claim on the device's audio route, and the SDK does not
///     support a second `connect` after a disconnect. So the engine is built by
///     ``beginCall()`` and dropped by ``endCall()``.
///
/// Getting that backwards is invisible until it is not: a per-call provider looks fine
/// on the first call, and a reused engine looks fine until the second one is silent.
///
/// ⛔ ONE ``AudioSessionCoordinator``, SHARED BY BOTH HALVES. CallKit activates the
/// session and the engine's speaker toggle overrides its output port; two coordinators
/// would mean the object that answered `provider(_:didActivate:)` was not the object
/// the speaker button had written to.
///
/// ⛔ IT IS ALSO WHERE "WHO OWNS THIS DEVICE'S AUDIO" LIVES, WHICH IS A THIRD JOB AND
/// BELONGS HERE FOR THE SAME REASON THE FIRST TWO DO. A meeting room is not a telephone
/// call — it never reaches ``CallKitBridge``, by design — but it takes the same one
/// `AVAudioSession` and the same one microphone, and without a shared object the two
/// sides cannot see each other at all: rooms would consult ``engine``, which is nil for
/// the whole of a ring, and calls ``onSystemRequest``, which knows nothing about rooms.
/// This type is the only object both sides already hold, so ``hasLiveCall``,
/// ``hasLiveRoom`` and ``endRoom(_:)`` make the exclusion mutual.
///
/// ⚠️ IT COMPOSES NOTHING ABOVE THE PLATFORM. ``SoftphoneSession``, the dial
/// repository, the tick timer and the screen belong to ``DialerModel``; this exists so
/// that model has one entry point instead of three constructors and a wiring
/// paragraph. It lives on the container as ``AppContainer/callStack``, which costs
/// nothing up front: constructing a `CXProvider` and a coordinator registers nothing
/// with the OS until a call is started or reported.
///
/// ⚠️ `@MainActor` BECAUSE ``CallKitBridge`` IS. Everything underneath is `Sendable`,
/// so reaching the nonisolated engine from here is an ordinary async call rather than
/// an actor hop.
@MainActor
final class CallStack {
    /// What the OS is told, and what it asks for back. ⛔ Process-lifetime.
    let callKit: CallKitBridge

    /// The single owner of `AVAudioSession`. ⛔ Process-lifetime, shared with the engine.
    let audio: AudioSessionCoordinator

    /// The engine for the call in progress, or nil between calls.
    ///
    /// ⚠️ EXPOSED AS ``CallEngine`` RATHER THAN AS THE CONCRETE TYPE, so a caller
    /// cannot reach a LiveKit symbol through it. The seam is the point.
    private(set) var engine: (any CallEngine)?

    /// Where a system-originated request goes. ⛔ Set it before starting or reporting
    /// any call; see the ⛔ on ``CallKitBridge/onSystemRequest``.
    var onSystemRequest: ((CallKitRequest) -> Void)? {
        get { callKit.onSystemRequest }
        set { callKit.onSystemRequest = newValue }
    }

    /// The live meeting room, or nil.
    ///
    /// ⛔ HELD STRONGLY, AND THAT IS THE POINT RATHER THAN A LEAK. It is the same
    /// lifetime rule ``onSystemRequest`` gives a call: a live thing that owns the
    /// microphone must outlive the screen that started it, because the screen can be
    /// destroyed by a sign-out or a workspace switch with nobody having asked to leave
    /// the meeting. ⛔ The other half of that bargain is that SOMETHING must end it —
    /// see ``endRoom(_:)`` and its three callers — since an object nothing can reach
    /// and nothing releases is a microphone that publishes for the life of the
    /// process. Without the claim a model dies with its view while its pump task holds
    /// the engine STRONGLY, so the `Room`, its socket and its published tracks outlive
    /// everything and `disconnect()` is reached from no path but the Leave button.
    ///
    /// ⚠️ IT IS ALSO HOW A ROOM SCREEN FINDS ITS MEETING AGAIN. A screen rebuilt around a
    /// live room (a sidebar section chosen and chosen back, a rotation that swaps the tab
    /// bar for the sidebar) re-attaches to this model rather than opening a fresh one on
    /// a Join button; see `ActiveRoomView`'s initialiser.
    private(set) var room: (any RoomAudio)?

    /// The outbound dialler that owns the live call, so a dial screen rebuilt around the
    /// call can find it again, or nil.
    ///
    /// ⛔ WEAK, BECAUSE THE CLAIM ALREADY KEEPS IT ALIVE. ``onSystemRequest`` captures the
    /// dialler strongly for exactly the length of one call; this only makes the object
    /// the claim holds reachable by a screen. A strong reference here would be a second
    /// lifetime nothing releases.
    ///
    /// ⚠️ `AnyObject` RATHER THAN THE MODEL'S TYPE, for the reason ``room`` is a protocol:
    /// this tier names no feature type. The dialler casts it back.
    weak var softphone: AnyObject?

    /// Whether a telephone call is live on this device, in either direction.
    ///
    /// ⛔ THE CLAIM ON ``onSystemRequest``, NOT ``engine``, AND THE DIFFERENCE IS THE
    /// WHOLE LENGTH OF A CALL. The engine is built at MEDIA time (``beginCall()``), so
    /// `engine == nil` is true throughout the entire 30-second inbound ring and the
    /// whole outbound window between the Call tap and the dial being accepted, so a
    /// room guard that tested it would let a room be joined during a live ring while
    /// the screen promised the opposite. The claim is set
    /// before the first CallKit transaction and dropped on every terminal path, which
    /// is exactly the interval a room must not overlap, and it is the predicate both
    /// call models already use on each other.
    var hasLiveCall: Bool {
        onSystemRequest != nil
    }

    /// Whether a meeting room owns this device's audio.
    var hasLiveRoom: Bool {
        room != nil
    }

    /// Whether this app may use the microphone, and the one way to ask. ⛔ Asked by both call
    /// models before their media join can fail for want of it; see ``MicrophoneAccess``.
    let microphone: any MicrophoneAccess

    /// - Parameter microphone: the permission seam. ⚠️ The live one everywhere but a test.
    init(microphone: any MicrophoneAccess = LiveMicrophoneAccess()) {
        let audio = AudioSessionCoordinator()
        self.audio = audio
        self.microphone = microphone
        callKit = CallKitBridge(audio: audio)
    }

    /// Build the engine for one call and hand back everything it will report.
    ///
    /// ⛔ THE RETURNED STREAM IS READ EXACTLY ONCE. `AsyncStream` delivers each element
    /// to a SINGLE consumer, so a second `for await` over it silently splits the events
    /// between two readers rather than mirroring them — half the reducer's input,
    /// chosen at random. The owner of the call reads it and feeds
    /// ``SoftphoneEvent/engine(_:)`` or ``IncomingCallEvent/engine(_:)``.
    ///
    /// ⚠️ IT TEARS DOWN A PREVIOUS ENGINE RATHER THAN LEAKING ONE. Reaching here with a
    /// call already live would be a bug in the caller (one call at a time is an
    /// invariant of the product, and ``CallKitBridge`` declares it to the OS as
    /// `maximumCallGroups = 1`), but a leaked engine holds a socket and the audio route
    /// indefinitely, so the safe thing is done rather than assumed.
    ///
    /// ⛔ AND IT TAKES THE AUDIO OFF A LIVE ROOM FIRST, WHICH IS WHY IT IS ASYNC. This
    /// is the moment a call takes the device: the object built on the next line turns
    /// `isAutomaticConfigurationEnabled` off and publishes a microphone. A room that
    /// was still up here would be a second owner of one `AVAudioSession` and, worse
    /// than a routing fault, a private customer call audible to a meeting and a meeting
    /// audible to the caller. Doing it HERE rather than in each call model is what
    /// makes it true for both directions and impossible for a new call path to forget.
    ///
    /// ⚠️ IT IS AWAITED RATHER THAN SPAWNED, UNLIKE ``endCall()``. "One owner" is only
    /// true if the previous one is gone before the next one starts; a fire-and-forget
    /// teardown would make it eventually true, which is not a property worth having
    /// here. The cost is that an answered call waits on one `Room.disconnect()`.
    ///
    /// ⚠️ ON THE OUTBOUND PATH THIS IS ALREADY A NO-OP. ``DialerModel/placeCall()``
    /// refuses a dial while a room is live, so only an inbound answer reaches here with
    /// a room to yield. See the ⛔ on ``RoomAudioYield/telephoneCall``.
    func beginCall() async -> AsyncStream<CallEngineEvent> {
        await endRoom(.telephoneCall)
        endCall()
        let engine = LiveKitCallEngine(audio: audio)
        self.engine = engine
        return engine.events
    }

    /// Record that a room owns this device's audio.
    ///
    /// ⚠️ LAST WRITER WINS, AND IT IS SAFE ONLY BECAUSE ``ActiveRoomModel/join()``
    /// REFUSES WHILE ``hasLiveRoom`` IS TRUE. A second claim would otherwise drop the
    /// first model's only reference and leave its engine unreachable, which is the leak
    /// this claim exists to close.
    func claimRoom(_ owner: any RoomAudio) {
        room = owner
    }

    /// Give the claim back. ⛔ Identity-checked, so a model that has already yielded
    /// cannot release a later model's room.
    func releaseRoom(_ owner: any RoomAudio) {
        guard room === owner else { return }
        room = nil
    }

    /// End the live room, if there is one, and tell it why.
    ///
    /// ⛔ THE CLAIM IS DROPPED BEFORE THE ROOM IS TOLD, WHICH IS WHAT KEEPS THIS
    /// IDEMPOTENT. ``ActiveRoomModel/yieldAudio(_:)`` calls ``releaseRoom(_:)`` on its
    /// way out; releasing first means that call finds nothing rather than racing this
    /// one, and a second `endRoom` during the await cannot ask the same room twice.
    ///
    /// ⚠️ SAFE AND CHEAP WITH NO ROOM LIVE, which is most of the time — every answered
    /// call goes through it.
    func endRoom(_ reason: RoomAudioYield) async {
        guard let room else { return }
        self.room = nil
        await room.yieldAudio(reason)
    }

    /// Release the engine once the call's reducer has reached a terminal phase.
    ///
    /// ⚠️ NOT A HANG-UP. The reducers emit ``CallCommand/disconnect`` themselves, exactly
    /// once, on every terminal path; this drops the object afterwards. The disconnect
    /// here is belt and braces for the caller that forgets, and it is safe because
    /// ``CallEngine/disconnect()`` is idempotent by contract.
    ///
    /// ⚠️ FIRE AND FORGET. Nothing waits on a socket closing to leave a call screen.
    func endCall() {
        guard let previous = engine else { return }
        engine = nil
        Task { await previous.disconnect() }
    }

    /// Perform one reducer's command list.
    ///
    /// ⛔ IN ORDER, SEQUENTIALLY, AND THE ORDER IS PART OF THE CONTRACT. ``CallCommand``
    /// says so: "the microphone is turned on before the OS is told the call is active"
    /// is an assertion about a list, and running the list concurrently would make it an
    /// assertion about nothing.
    func perform(_ commands: [CallCommand]) async {
        for command in commands {
            await perform(command)
        }
    }

    /// ⛔ A COMMAND WITH NO ENGINE IS DROPPED, AND ONLY ONE KIND CAN GET HERE. Both
    /// reducers emit ``CallCommand/disconnect`` on terminal paths that never issued a
    /// connect — a refused dial, a declined ring — and dropping it is exactly right:
    /// there is nothing to disconnect. ``CallCommand/connect(url:token:)`` cannot reach
    /// here at all, because a terminal phase absorbs every later event, so the only
    /// list that follows an ``endCall()`` is an empty one.
    ///
    /// ⚠️ THE CONNECT ERROR IS SWALLOWED, WHICH IS WHAT ``CallEngine/connect(url:token:)``
    /// asks for. The engine has already emitted ``CallEngineEvent/failed(message:)``, so
    /// the connection state is the user-facing outcome; letting the error escape would
    /// crash the process over a network condition.
    func perform(_ command: CallCommand) async {
        guard let engine else { return }
        switch command {
        case let .connect(url, token):
            try? await engine.connect(url: url, token: token)
        case .disconnect:
            await engine.disconnect()
        case let .setMuted(muted):
            await engine.setMuted(muted)
        case let .setSpeakerphone(enabled):
            await engine.setSpeakerphone(enabled)
        }
    }
}
