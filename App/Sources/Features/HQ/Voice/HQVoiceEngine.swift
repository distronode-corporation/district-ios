import DistrictModel
import Foundation
import LiveKit
import OSLog

/// ⚠️ THE SDK'S OWN TEXT GOES TO THE LOG, NEVER ON SCREEN, as in ``RoomEngine``. The token
/// and the session id never go anywhere.
private let voiceLog = Logger(subsystem: "com.distronode.district", category: "HQVoice")

/// One piece of the transcription: a segment's text so far, whose words they are, and
/// whether it is final.
struct HQVoiceSegment: Identifiable, Sendable, Equatable {
    let id: String
    let text: String
    let isFinal: Bool
    /// The member's own words (`lk.transcribed_track_id` is the member's microphone track),
    /// otherwise HQ's.
    let fromMember: Bool
}

extension HQVoiceSegment {
    /// A segment whose text stream has CLOSED.
    ///
    /// ⛔ A CLOSED STREAM IS A FINAL SEGMENT, whatever `lk.transcription_final` says or whether it
    /// arrived at all: the whole text is only handed over once its stream closes, and the agent
    /// may send the flag at the close rather than in the header. Waiting for a flag that never
    /// came would drop HQ's words from the transcript.
    init(closedStream streamID: String, attributes: [String: String], text: String, memberTrack: String?) {
        let transcribed = attributes[HQVoice.transcribedTrackIDAttribute]
        self.init(
            id: attributes[HQVoice.segmentIDAttribute] ?? streamID,
            text: text,
            isFinal: true,
            fromMember: transcribed != nil && transcribed == memberTrack
        )
    }
}

/// What an HQ voice room tells the session.
enum HQVoiceEngineEvent: Sendable, Equatable {
    case connected
    case disconnected
    case transcript(HQVoiceSegment)
    case packet(HQVoicePacket)
    case agentState(HQAgentState)
    /// The agent participant left the room.
    case agentLeft
}

/// The LiveKit side of an HQ voice session: join one encrypted room, publish the microphone
/// and nothing else, and report what the room says. ``HQVoiceSession`` holds the rules.
///
/// ⚠️ A PROTOCOL SO THE SESSION RUNS AGAINST A FAKE IN TESTS and a staged engine in the
/// debug screenshot lane, with no room and no network.
@MainActor
protocol HQVoiceEngine: AnyObject {
    var events: AsyncStream<HQVoiceEngineEvent> { get }
    func connect(url: String, token: String) async throws
    /// Turns the microphone on or off; answers what the SDK accepted.
    func setMicrophone(enabled: Bool) async -> Bool
    func disconnect() async
}

/// The LiveKit room for HQ by voice.
///
/// ⛔ A THIRD ENGINE BESIDE ``LiveKitCallEngine`` AND ``RoomEngine``, NOT A WIDENING OF EITHER,
/// for ``RoomEngine``'s reason: nothing in the call path is touched. It never reaches
/// CallKit, and the overlap with a call or a meeting is kept out by ``CallStack``, which
/// the session claims for its whole length.
///
/// ⛔ ALWAYS ENCRYPTED. The key is handed to LiveKit's key provider verbatim, as
/// ``RoomEngine`` does; the session joins only a credential that
/// ``HQVoiceTokenResponse/isJoinable`` passed.
///
/// ⛔ IT PUBLISHES THE MICROPHONE AND NO DATA, and the microphone is OFF at the join: the
/// session decides when it opens (``HQMicMode``).
@MainActor
final class LiveKitHQVoiceEngine: HQVoiceEngine {
    let events: AsyncStream<HQVoiceEngineEvent>
    private let continuation: AsyncStream<HQVoiceEngineEvent>.Continuation
    private let bridge: HQVoiceRoomBridge
    private let room: Room

    init(e2eeKey: String) {
        let (stream, continuation) = AsyncStream<HQVoiceEngineEvent>.makeStream()
        events = stream
        self.continuation = continuation
        let bridge = HQVoiceRoomBridge(continuation: continuation)
        self.bridge = bridge
        let provider = BaseKeyProvider(isSharedKey: true, sharedKey: e2eeKey)
        room = Room(delegate: bridge, roomOptions: RoomOptions(e2eeOptions: E2EEOptions(keyProvider: provider)))
        bridge.room = room
    }

    func connect(url: String, token: String) async throws {
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = true
        let continuation = continuation
        let room = room
        try await room.registerTextStreamHandler(for: HQVoice.transcriptionTopic) { reader, _ in
            let text = try await reader.readAll()
            // ⚠️ READ AFTER THE STREAM CLOSED, so attributes sent at the close are seen.
            continuation.yield(.transcript(HQVoiceSegment(
                closedStream: reader.info.id,
                attributes: reader.info.attributes,
                text: text,
                memberTrack: room.localParticipant.localAudioTracks.first?.sid.stringValue
            )))
        }
        do {
            try await room.connect(url: url, token: token)
        } catch {
            voiceLog.info("join failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func setMicrophone(enabled: Bool) async -> Bool {
        do {
            try await room.localParticipant.setMicrophone(enabled: enabled)
            return enabled
        } catch {
            return !enabled
        }
    }

    func disconnect() async {
        await room.unregisterTextStreamHandler(for: HQVoice.transcriptionTopic)
        await room.disconnect()
        continuation.finish()
    }
}

/// Turns `RoomDelegate` callbacks into ``HQVoiceEngineEvent`` values.
private final class HQVoiceRoomBridge: NSObject, RoomDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<HQVoiceEngineEvent>.Continuation
    weak var room: Room?

    init(continuation: AsyncStream<HQVoiceEngineEvent>.Continuation) {
        self.continuation = continuation
    }

    @objc
    func room(
        _ room: Room,
        didUpdateConnectionState connectionState: ConnectionState,
        from oldConnectionState: ConnectionState
    ) {
        if connectionState == .connected {
            continuation.yield(.connected)
        }
    }

    @objc
    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        if let error {
            voiceLog.info("room disconnected: \(error.localizedDescription, privacy: .public)")
        }
        continuation.yield(.disconnected)
    }

    /// ⚠️ A PACKET THAT DOES NOT VALIDATE IS IGNORED, never an error (``HQVoicePacket/read(_:)``).
    @objc
    func room(
        _ room: Room,
        participant: RemoteParticipant?,
        didReceiveData data: Data,
        forTopic topic: String,
        encryptionType: EncryptionType
    ) {
        guard topic == HQVoice.proposalTopic, let packet = HQVoicePacket.read(data) else { return }
        continuation.yield(.packet(packet))
    }

    /// ⛔ THE AGENT LEAVING ENDS THE SESSION (as on the web): the room may stay open with nobody
    /// to talk to, and the service's row with it.
    @objc
    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        guard participant.kind == .agent else { return }
        continuation.yield(.agentLeft)
    }

    @objc
    func room(_ room: Room, participant: Participant, didUpdateAttributes attributes: [String: String]) {
        guard participant.kind == .agent,
              let state = attributes[HQVoice.agentStateAttribute].flatMap(HQAgentState.init(wire:))
        else { return }
        continuation.yield(.agentState(state))
    }
}
