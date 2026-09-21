import Foundation

/// A media session, as the persona preview needs to see one.
///
/// ⛔ A SEAM SO THE STATE MACHINE IS REACHABLE WITHOUT LIVEKIT, WHICH IS THE ONLY WAY
/// ANY OF IT IS CHECKED. A preview is a real, billed call — the token invites the voice
/// agent into a room on the workspace's own pipeline — so "start it and see" is not an
/// available way to find out whether the phase transitions, the arbitration and the
/// teardown are right. Everything above this protocol is ordinary code with a fake
/// behind it; everything below it is the SDK.
///
/// ⛔ IT IS DELIBERATELY NARROWER THAN ``RoomEngine`` AND MUST STAY THAT WAY. There is
/// no camera member and no data channel here: a persona audition publishes a microphone
/// and subscribes to the agent's audio, and a seam that offered a camera would make
/// "audio only" a claim in a comment rather than a property of the type. ⚠️ `RoomEngine`
/// still HAS those members — this is a view onto it, not a different engine.
///
/// ⚠️ `RoomEngine` RATHER THAN `LiveKitCallEngine` IS NOT A PREFERENCE. `CallEngine`'s
/// `connect(url:token:)` takes no encryption key, by documented decision, and a
/// `preview_*` room is always end-to-end encrypted — a client that joined it
/// unencrypted would be the only such participant in the room, publishing and hearing
/// noise while every connection succeeded.
protocol PersonaPreviewEngine: AnyObject, Sendable {
    /// ⚠️ READ EXACTLY ONCE. `AsyncStream` hands each element to a single consumer, so
    /// a second `for await` splits the events between two readers rather than mirroring
    /// them.
    var events: AsyncStream<RoomEngineEvent> { get }

    func connect(url: String, token: String) async throws

    /// ⛔ IDEMPOTENT BY CONTRACT. Every teardown path depends on it.
    func disconnect() async

    /// - Returns: what the SDK ACCEPTED, never what was asked for. A refusal leaves the
    ///   caller holding the truth, which is the direction that matters: the alternative
    ///   invites somebody to speak on a line nobody can hear.
    func setMicrophone(enabled: Bool) async -> Bool

    func setSpeakerphone(_ enabled: Bool)

    /// Who else is in the room, and how loud they are.
    ///
    /// ⛔ PULLED ON DEMAND RATHER THAN PUSHED THROUGH ``events``, for the reason
    /// ``RoomEngine/roster()`` states: a snapshot holds a live SDK video handle and is
    /// not `Sendable`, so the stream carries signals and the reader asks for the state.
    func roster() -> [RoomParticipantSnapshot]
}

/// ⚠️ EVERY MEMBER ALREADY EXISTS ON ``RoomEngine`` WITH THE SAME SIGNATURE, so this
/// conformance adds no code and no second implementation of anything. That is the test
/// of whether a seam is a view onto something or a fork of it.
extension RoomEngine: PersonaPreviewEngine {}
