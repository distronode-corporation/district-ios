@testable import DistrictAI
import DistrictModel
import XCTest

/// The session, a fake room and a stub service, for ``HQVoiceSessionTests`` and
/// ``HQVoiceSessionLiveTests``.
@MainActor
class HQVoiceSessionCase: XCTestCase {
    var transport = HQVoiceTransport()
    var engine = FakeHQVoiceEngine()
    var stack = CallStack(microphone: FakeMicrophoneAccess(status: .granted))
    var slept: [TimeInterval] = []
    /// Each agent-join window the session opened, and how many were cancelled before they ran out.
    var waitedForAgent: [TimeInterval] = []
    var agentWaitsCancelled = 0

    override func setUp() async throws {
        transport = HQVoiceTransport()
        transport.reply("voice-token", 200, HQVoiceTransport.token())
        transport.reply("voice-context", 200, #"{"success":true}"#)
        transport.reply("voice-end", 200, #"{"success":true,"ended":true}"#)
        transport.reply("voice-discard", 200, #"{"success":true,"discarded":true}"#)
        engine = FakeHQVoiceEngine()
        stack = CallStack(microphone: FakeMicrophoneAccess(status: .granted))
        stack.voiceEndDeadline = Self.noVoiceEndDeadline
        slept = []
        waitedForAgent = []
        agentWaitsCancelled = 0
    }

    /// A session whose 30-minute clock never rings unless `timesOut`, and whose agent-join window
    /// never runs out unless `agentNeverJoins`.
    func makeSession(
        microphone: any MicrophoneAccess = FakeMicrophoneAccess(status: .granted),
        canConfirm: Bool = true,
        timesOut: Bool = false,
        agentNeverJoins: Bool = false
    ) -> HQVoiceSession {
        let engine = engine
        return HQVoiceSession(
            workspaceId: "ws1",
            canConfirm: canConfirm,
            hq: transport.repository,
            callStack: stack,
            microphone: microphone,
            makeEngine: { _ in engine },
            sleep: { [weak self] seconds in
                await MainActor.run { self?.slept.append(seconds) }
                if !timesOut {
                    try await Task.sleep(for: .seconds(3600))
                }
            },
            waitForAgent: { [weak self] seconds in
                await MainActor.run { self?.waitedForAgent.append(seconds) }
                guard !agentNeverJoins else { return }
                do {
                    try await Task.sleep(for: .seconds(3600))
                } catch {
                    await MainActor.run { self?.agentWaitsCancelled += 1 }
                    throw error
                }
            }
        )
    }

    /// A sign-out deadline that never runs out on its own, so only the end decides the wait.
    static let noVoiceEndDeadline: @Sendable (TimeInterval) async -> Void = { _ in
        try? await Task.sleep(for: .seconds(3600))
    }

    var discarded: Int {
        transport.count("voice-discard")
    }

    var ended: Int {
        transport.count("voice-end")
    }

    func goLive(_ session: HQVoiceSession) async {
        await session.start(history: [], locale: "en")
        await session.begin()
    }
}
