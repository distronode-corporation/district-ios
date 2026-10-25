@testable import DistrictAI
import DistrictModel
import Foundation
import XCTest

/// The push-to-start token (3.2): sent while signed in, for the current workspace, once per
/// token and workspace until it is a week old, and never retried.
@MainActor
final class LiveActivityStartTokensTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_793_000_000)
    private var clock: Date!
    private var workspace: String?
    private var memory: MemoryStore!
    private var registrar: StartRegistrar!
    private var deliver: (@MainActor (Data) -> Void)?
    private var observations = 0

    override func setUp() async throws {
        clock = start
        workspace = "ws_1"
        memory = MemoryStore()
        registrar = StartRegistrar()
        deliver = nil
        observations = 0
    }

    private func make() -> LiveActivityStartTokens {
        LiveActivityStartTokens(
            registrar: registrar,
            memory: memory,
            workspace: { [unowned self] in workspace },
            now: { [unowned self] in clock },
            observe: { [unowned self] onToken in
                observations += 1
                deliver = onToken
                return Task {}
            }
        )
    }

    func testATokenIsSentForTheCurrentWorkspaceAndRemembered() async {
        let tokens = make()
        tokens.begin()
        deliver?(Data([0xAB, 0x01]))

        await waitUntil { self.memory.sent != nil }
        XCTAssertEqual(registrar.calls, [["ws_1", "ab01"]])
        XCTAssertEqual(memory.sent, LiveActivityStartTokenSent(token: "ab01", workspaceId: "ws_1", sentAt: start))
    }

    /// ⛔ NOTHING IS SENT BEFORE SIGN-IN, and the observation starts once however often the
    /// app signs in.
    func testNothingIsSentSignedOutAndTheObservationStartsOnce() async {
        let tokens = make()
        tokens.workspaceChanged()
        XCTAssertNil(deliver)
        tokens.begin()
        tokens.begin()
        XCTAssertEqual(observations, 1)

        tokens.stop()
        deliver?(Data([0x01]))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(registrar.calls, [])
    }

    func testNoWorkspaceSendsNothing() async {
        workspace = nil
        let tokens = make()
        tokens.begin()
        deliver?(Data([0x01]))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(registrar.calls, [])
    }

    /// The same token for the same workspace is not sent again at launch until it is a week old.
    func testALaunchSendsAgainOnlyOnceTheTokenIsStale() async {
        memory.sent = LiveActivityStartTokenSent(token: "01", workspaceId: "ws_1", sentAt: start)
        let tokens = make()
        tokens.begin()
        deliver?(Data([0x01]))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(registrar.calls, [])

        clock = start.addingTimeInterval(LiveActivityStartTokens.staleAfter)
        tokens.begin()
        await waitUntil { self.registrar.calls.count == 1 }
        XCTAssertEqual(memory.sent?.sentAt, clock)
    }

    /// A workspace switch and a rotated token each send again.
    func testAWorkspaceSwitchAndANewTokenEachSendAgain() async {
        let tokens = make()
        tokens.begin()
        deliver?(Data([0x01]))
        await waitUntil { self.registrar.calls.count == 1 }

        workspace = "ws_2"
        tokens.workspaceChanged()
        await waitUntil { self.registrar.calls.count == 2 }
        deliver?(Data([0x02]))
        await waitUntil { self.registrar.calls.count == 3 }

        XCTAssertEqual(registrar.calls, [["ws_1", "01"], ["ws_2", "01"], ["ws_2", "02"]])
    }

    /// ⛔ A FAILURE IS NOT RETRIED AND NOT REMEMBERED: the next moment sends again. Two
    /// triggers while one request is on the wire send it once.
    func testAFailureIsNotRememberedAndConcurrentTriggersSendOnce() async {
        registrar.result = .failure(.transport("offline"))
        registrar.delay = true
        let tokens = make()
        tokens.begin()
        deliver?(Data([0x01]))
        tokens.workspaceChanged()
        registrar.release()
        await waitUntil { self.registrar.finished == 1 }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(registrar.calls.count, 1)
        XCTAssertNil(memory.sent)

        registrar.delay = false
        tokens.workspaceChanged()
        await waitUntil { self.registrar.calls.count == 2 }
    }

    /// ⛔ A SIGN-OUT WHILE THE REQUEST IS ON THE WIRE WINS, and it clears the memory.
    func testASignOutDuringTheRequestRemembersNothing() async {
        memory.sent = LiveActivityStartTokenSent(token: "00", workspaceId: "ws_1", sentAt: start)
        registrar.delay = true
        let tokens = make()
        tokens.begin()
        deliver?(Data([0x01]))
        tokens.stop()
        XCTAssertNil(memory.sent)
        registrar.release()
        await waitUntil { self.registrar.finished == 1 }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(memory.sent)
    }

    func testTheDefaultsMemoryRoundTrips() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "la-start-\(UUID().uuidString)"))
        let store = UserDefaultsLiveActivityStartTokenMemory(defaults: defaults)
        XCTAssertNil(store.load())
        let sent = LiveActivityStartTokenSent(token: "ab", workspaceId: "ws_1", sentAt: start)
        store.save(sent)
        XCTAssertEqual(store.load(), sent)
        store.save(nil)
        XCTAssertNil(store.load())
    }
}

private final class MemoryStore: LiveActivityStartTokenMemory {
    var sent: LiveActivityStartTokenSent?

    func load() -> LiveActivityStartTokenSent? {
        sent
    }

    func save(_ sent: LiveActivityStartTokenSent?) {
        self.sent = sent
    }
}

@MainActor
private final class StartRegistrar: LiveActivityStartTokenRegistering, @unchecked Sendable {
    private(set) var calls: [[String]] = []
    private(set) var finished = 0
    var result: Result<Void, ApiError> = .success(())
    var delay = false
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false

    func release() {
        released = true
        gate?.resume()
        gate = nil
    }

    nonisolated func registerLiveActivityStartToken(
        workspaceId: String,
        token: String
    ) async -> Result<Void, ApiError> {
        await record(workspaceId: workspaceId, token: token)
    }

    private func record(workspaceId: String, token: String) async -> Result<Void, ApiError> {
        calls.append([workspaceId, token])
        if delay, !released {
            await withCheckedContinuation { gate = $0 }
        }
        finished += 1
        return result
    }
}
