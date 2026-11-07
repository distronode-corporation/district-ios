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

    override func setUp() async throws {
        transport = HQVoiceTransport()
        transport.reply("voice-token", 200, HQVoiceTransport.token())
        transport.reply("voice-context", 200, #"{"success":true}"#)
        transport.reply("voice-end", 200, #"{"success":true,"ended":true}"#)
        transport.reply("voice-discard", 200, #"{"success":true,"discarded":true}"#)
        engine = FakeHQVoiceEngine()
        stack = CallStack(microphone: FakeMicrophoneAccess(status: .granted))
        slept = []
    }

    /// A session whose 30-minute clock never rings unless `timesOut`.
    func makeSession(
        microphone: any MicrophoneAccess = FakeMicrophoneAccess(status: .granted),
        canConfirm: Bool = true,
        timesOut: Bool = false
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
            }
        )
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
