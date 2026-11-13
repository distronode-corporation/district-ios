@testable import DistrictAI
import DistrictModel
import XCTest

/// A sign-out while HQ voice is still minting (#116): the token is waited for and given back
/// with the credential before the sign-out finishes, inside the sign-out's 3-second bound.
@MainActor
final class HQVoiceSignOutMintTests: HQVoiceSessionCase {
    /// Each sign-out deadline that ran out.
    var deadlinesRunOut: [TimeInterval] = []

    /// ⛔ A SIGN-OUT WHILE THE TOKEN MINTS WAITS FOR IT AND GIVES IT BACK (#116): the discard
    /// goes out with the credential, before the sign-out finishes, not after the revoke.
    func testTheSignOutDuringTheMintDiscardsTheSessionFirst() async throws {
        let container = try AppContainer(
            baseURL: XCTUnwrap(URL(string: "https://calls.invalid")),
            microphone: FakeMicrophoneAccess(status: .granted)
        )
        let session = makeSession()
        container.callStack.hqVoice = session
        container.callStack.voiceEndDeadline = Self.noVoiceEndDeadline
        transport.hold("voice-token")
        let starting = Task { await session.start(history: [], locale: "en") }
        let minting = await eventually { transport.isHolding }
        XCTAssertTrue(minting)
        let model = SessionModel(container: container, push: PushRegistrar(container: container))
        let signingOut = Task { await model.signOut() }
        let waiting = await eventually { model.isBusy && session.phase == .idle }
        XCTAssertTrue(waiting, "the sign-out reached the voice end, got \(session.phase)")
        if case .signedOut = model.phase {
            XCTFail("the sign-out did not wait for the token in flight")
        }
        XCTAssertEqual(discarded, 0)
        transport.release()
        await signingOut.value
        await starting.value
        guard case .signedOut = model.phase else { return XCTFail("got \(model.phase)") }
        XCTAssertEqual(discarded, 1, "discarded before the sign-out finished")
        XCTAssertEqual(ended, 0)
        XCTAssertEqual(transport.authorizations("voice-discard"), ["Bearer session-token"])
        XCTAssertTrue(try XCTUnwrap(transport.bodies("voice-discard").first).contains("sess-secret"))
        XCTAssertEqual(session.phase, .idle)
        XCTAssertNil(engine.joined)
    }

    /// ⛔ A REFUSED DISCARD DURING THE SIGN-OUT FALLS BACK TO THE END, also before it finishes.
    func testTheSignOutDuringTheMintEndsARefusedDiscard() async throws {
        let container = try AppContainer(
            baseURL: XCTUnwrap(URL(string: "https://calls.invalid")),
            microphone: FakeMicrophoneAccess(status: .granted)
        )
        transport.reply("voice-discard", 200, #"{"success":true,"discarded":false}"#)
        let session = makeSession()
        container.callStack.hqVoice = session
        container.callStack.voiceEndDeadline = Self.noVoiceEndDeadline
        transport.hold("voice-token")
        let starting = Task { await session.start(history: [], locale: "en") }
        let minting = await eventually { transport.isHolding }
        XCTAssertTrue(minting)
        let model = SessionModel(container: container, push: PushRegistrar(container: container))
        let signingOut = Task { await model.signOut() }
        let waiting = await eventually { model.isBusy && session.phase == .idle }
        XCTAssertTrue(waiting)
        transport.release()
        await signingOut.value
        await starting.value
        guard case .signedOut = model.phase else { return XCTFail("got \(model.phase)") }
        XCTAssertEqual(discarded, 1)
        XCTAssertEqual(ended, 1, "ended before the sign-out finished")
        XCTAssertEqual(transport.authorizations("voice-end"), ["Bearer session-token"])
    }

    /// ⛔ A STOP DURING THE MINT, THEN A SIGN-OUT (Seer, PR #122): the phase has left `.minting`,
    /// and the sign-out still waits for the token and its discard.
    func testTheSignOutAfterAStopDuringTheMintStillWaitsForTheToken() async throws {
        let container = try AppContainer(
            baseURL: XCTUnwrap(URL(string: "https://calls.invalid")),
            microphone: FakeMicrophoneAccess(status: .granted)
        )
        let session = makeSession()
        container.callStack.hqVoice = session
        container.callStack.voiceEndDeadline = Self.noVoiceEndDeadline
        transport.hold("voice-token")
        let starting = Task { await session.start(history: [], locale: "en") }
        let minting = await eventually { transport.isHolding }
        XCTAssertTrue(minting)
        await session.stop()
        XCTAssertEqual(session.phase, .ended(.byMember))
        let model = SessionModel(container: container, push: PushRegistrar(container: container))
        let signingOut = Task { await model.signOut() }
        let waiting = await eventually { model.isBusy }
        XCTAssertTrue(waiting)
        if case .signedOut = model.phase {
            XCTFail("the sign-out did not wait for the token in flight")
        }
        transport.release()
        await signingOut.value
        await starting.value
        guard case .signedOut = model.phase else { return XCTFail("got \(model.phase)") }
        XCTAssertEqual(discarded, 1, "discarded before the sign-out finished")
        XCTAssertEqual(transport.authorizations("voice-discard"), ["Bearer session-token"])
    }

    /// ⛔ A MINT THAT STALLS PAST THE DEADLINE DOES NOT HOLD THE SIGN-OUT: it finishes at the
    /// deadline, and the token that arrives later is still given back.
    func testAStalledMintDoesNotHoldTheSignOut() async throws {
        let container = try AppContainer(
            baseURL: XCTUnwrap(URL(string: "https://calls.invalid")),
            microphone: FakeMicrophoneAccess(status: .granted)
        )
        let session = makeSession()
        container.callStack.hqVoice = session
        transport.hold("voice-token")
        let starting = Task { await session.start(history: [], locale: "en") }
        let minting = await eventually { transport.isHolding }
        XCTAssertTrue(minting)
        // The deadline runs out only once the sign-out is waiting on the stalled mint.
        container.callStack.voiceEndDeadline = { [weak self] seconds in
            while await MainActor.run(body: { session.phase != .idle }) {
                await Task.yield()
            }
            await MainActor.run { self?.deadlinesRunOut.append(seconds) }
        }
        let model = SessionModel(container: container, push: PushRegistrar(container: container))
        await model.signOut()
        XCTAssertEqual(deadlinesRunOut, [CallStack.voiceEndSeconds])
        guard case .signedOut = model.phase else { return XCTFail("got \(model.phase)") }
        XCTAssertTrue(transport.isHolding, "the mint is still in flight after the sign-out")
        XCTAssertEqual(discarded, 0)
        transport.release()
        await starting.value
        let sent = await eventually { discarded == 1 }
        XCTAssertTrue(sent, "the late token is still discarded")
        XCTAssertEqual(session.phase, .idle)
    }
}
