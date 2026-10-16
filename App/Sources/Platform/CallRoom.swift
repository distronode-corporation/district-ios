import Foundation
import LiveKit

/// The three SDK calls a softphone call makes, behind a seam so their ORDER is tested
/// without a media server (`LiveKitCallEngineJoinTests`).
///
/// ⛔ ``connect(url:token:)`` PUBLISHES NOTHING. The microphone is started afterwards, by
/// ``LiveKitCallEngine/connect(url:token:)``, with one ``setMicrophone(enabled:)``.
protocol CallRoom: AnyObject, Sendable {
    /// Join the room, publishing nothing.
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
/// ⚠️ `@unchecked Sendable` because `Room` is the SDK's, and every stored property is a `let`.
final class LiveKitCallRoom: CallRoom, @unchecked Sendable {
    private let room: Room

    init(delegate: RoomDelegate) {
        // ⚠️ NO `roomOptions`. `adaptiveStream` and `dynacast` are video-only knobs and
        // ⛔ the softphone publishes no video at all, in either direction; the audio
        // capture and publish defaults are what a phone call wants.
        room = Room(delegate: delegate)
    }

    func connect(url: String, token: String) async throws {
        try await room.connect(
            url: url,
            token: token,
            connectOptions: ConnectOptions(enableMicrophone: false)
        )
    }

    func setMicrophone(enabled: Bool) async throws {
        try await room.localParticipant.setMicrophone(enabled: enabled)
    }

    func disconnect() async {
        await room.disconnect()
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
