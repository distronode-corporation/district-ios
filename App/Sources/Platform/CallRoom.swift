import Foundation
import LiveKit
import OSLog

/// A remote audio track this side could not subscribe to. Public, like the engine's: the
/// SDK's English error description and nothing personal.
private let subscribeLog = Logger(subsystem: "com.distronode.district", category: "Call")

/// The three SDK calls a softphone call makes, behind a seam so their ORDER is tested
/// without a media server (`LiveKitCallEngineJoinTests`).
///
/// ⛔ ``connect(url:token:)`` PUBLISHES NOTHING. The microphone is started afterwards, by
/// ``LiveKitCallEngine/connect(url:token:)``, with one ``setMicrophone(enabled:)``.
protocol CallRoom: AnyObject, Sendable {
    /// Join the room, publishing nothing and subscribed to nothing; the room's audio is
    /// subscribed once the join is done (``RemoteAudioSubscriber``).
    func connect(url: String, token: String) async throws

    /// Publish (the first time), unmute or mute the microphone.
    func setMicrophone(enabled: Bool) async throws

    /// Leave. ⛔ Idempotent, see ``LiveKitCallEngine/disconnect()``.
    func disconnect() async
}

/// The LiveKit `Room` behind ``CallRoom``.
///
/// ⛔ `enableMicrophone: false`, SPELLED OUT. LiveKit's concurrent microphone mode starts
/// the capture on the SDK's one serial WebRTC queue while the join is still building its
/// peer connections on that same queue, so a slow Core Audio start (VoiceProcessingIO
/// setting up its aggregate device) held the join until its transport timed out: the
/// server saw the session start and never become active, and the call ended "could not be
/// connected" (District AI for Mac 3.0.1, 2026-10-16, 05:46:05Z; this engine joins the
/// same way). Joining first and then publishing keeps a slow microphone off the join.
///
/// ⛔ `autoSubscribe: false`, AND THE SPEAKER IS THE SAME STORY. The join waits for the
/// SUBSCRIBER peer connection (protocol 16 makes it the primary one for a client that
/// publishes nothing), and it connects only after this side ANSWERS the server's first
/// offer. With auto-subscribe that offer already carries every remote audio track in the
/// room (the caller, the agent), and applying it starts the speaker: WebRTC calls the
/// audio device module's `InitPlayout`/`StartPlayout` synchronously on its worker thread,
/// which starts an `AVAudioEngine` (`audio_engine_device.mm`, up to ten start attempts
/// 100 ms apart). Until that returns, the answer is not sent. District AI for Mac 3.0.1
/// build 20062, 2026-10-16, 07:07:03Z: the server saw only the publisher connect, no
/// subscriber candidates ever arrived, and the SDK's ten-second primary-transport wait
/// ended the call "could not be connected". This engine joins the same way.
///
/// ⚠️ ON iOS THE SPEAKER STARTS AT THE SUBSCRIBE, NOT AT CALLKIT'S ACTIVATION. The SDK's
/// session automation is off (``LiveKitCallEngine/connect(url:token:)``), but nothing here
/// gates the audio engine (`AudioManager.setEngineAvailability`), so the engine starts the
/// moment WebRTC asks for playout, on an `AVAudioSession` that CallKit may still be
/// activating. iOS has no macOS `prepare` and 100 ms sleep in that path, so the stall is
/// less likely here than on the Mac, but the answer still waits on Core Audio. Joining
/// unsubscribed makes the first offer data channels only, so the join no longer waits on
/// it; the audio tracks are subscribed right after, by ``RemoteAudioSubscriber``, and a
/// slow speaker start then delays the first second of sound instead of failing the call.
///
/// ⚠️ `@unchecked Sendable` because `Room` is the SDK's, and every stored property is a `let`.
final class LiveKitCallRoom: CallRoom, @unchecked Sendable {
    /// The options every softphone join uses: nothing published, nothing subscribed. Named
    /// so a test pins both (`LiveKitCallEngineJoinTests`).
    static let connectOptions = ConnectOptions(autoSubscribe: false, enableMicrophone: false)

    private let room: Room

    /// ⚠️ HELD BECAUSE THE ROOM'S DELEGATES ARE WEAK, like ``LiveKitCallEngine``'s bridge.
    private let audio = RemoteAudioSubscriber()

    init(delegate: RoomDelegate) {
        // ⚠️ NO `roomOptions`. `adaptiveStream` and `dynacast` are video-only knobs and
        // ⛔ the softphone publishes no video at all, in either direction; the audio
        // capture and publish defaults are what a phone call wants.
        room = Room(delegate: delegate)
        room.add(delegate: audio)
    }

    func connect(url: String, token: String) async throws {
        try await room.connect(
            url: url,
            token: token,
            connectOptions: Self.connectOptions
        )
        // ⚠️ THE TRACKS ALREADY IN THE ROOM AT THE JOIN. The SDK announces a publication only
        // once the room is connected, so the ones the join response carried are never
        // announced; every later one is, to ``RemoteAudioSubscriber``. A track announced
        // while this loop runs is subscribed twice, which the SDK ignores.
        RemoteAudioSubscriber.subscribeAll(in: room)
    }

    func setMicrophone(enabled: Bool) async throws {
        try await room.localParticipant.setMicrophone(enabled: enabled)
    }

    func disconnect() async {
        await room.disconnect()
    }
}

/// Subscribes this side to every remote audio track, which `autoSubscribe: false` leaves to
/// the app (see ``LiveKitCallRoom``).
///
/// ⛔ AUDIO ONLY, AND EVERY AUDIO TRACK. It replaces auto-subscribe for a softphone, which
/// receives no video; the caller, the agent and anyone transferred in must all be heard, so
/// nothing here chooses between them.
///
/// ⛔ THE SELECTOR IS SPELLED OUT. `RoomDelegate`'s members are `@objc optional`, so a
/// signature that does not match is not an error, the callback simply never fires, and the
/// symptom would be a call that connects and plays nothing. The name here is the SDK's
/// declaration (`room:remoteParticipant:didPublishTrack:`), checked against 2.17.0 and
/// pinned by `LiveKitCallEngineJoinTests`.
///
/// ⚠️ A FAILED SUBSCRIBE IS LOGGED, NOT SURFACED. The SDK refuses only when the room is
/// already gone, and the call's own end reaches the screen through the bridge.
final class RemoteAudioSubscriber: NSObject, RoomDelegate, @unchecked Sendable {
    @objc(room:remoteParticipant:didPublishTrack:)
    func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
        Self.subscribe(publication)
    }

    /// Subscribe to the audio tracks already published in `room`.
    static func subscribeAll(in room: Room) {
        for participant in room.remoteParticipants.values {
            for case let publication as RemoteTrackPublication in participant.trackPublications.values {
                subscribe(publication)
            }
        }
    }

    private static func subscribe(_ publication: RemoteTrackPublication) {
        guard publication.kind == .audio else { return }
        Task {
            do {
                try await publication.set(subscribed: true)
            } catch {
                subscribeLog.info("audio subscribe failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// Opens once the room's `.connected` has been put on the event stream, for an event that
/// must follow it.
///
/// ⚠️ WHY IT EXISTS: the SDK reports the connection state through its delegate queue,
/// asynchronously, so `connect` can return before ``CallEngineEvent/connected`` is yielded.
/// ``CallEngineEvent/microphoneChanged(enabled:)`` yielded first would reach a reducer still
/// answering, which drops it, and the screen would show a live microphone that never started.
///
/// ⚠️ `@unchecked Sendable`: the state is behind the lock.
final class ConnectedLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Open the latch and release every waiter. Opening it again changes nothing.
    func open() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            let waiting = waiters
            waiters = []
            return waiting
        }
        for waiter in waiting {
            waiter.resume()
        }
    }

    /// Return once the latch is open, at once if it already is.
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let openAlready: Bool = lock.withLock {
                if isOpen {
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if openAlready {
                continuation.resume()
            }
        }
    }
}
