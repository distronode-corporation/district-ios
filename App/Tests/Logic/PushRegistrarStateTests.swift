@testable import DistrictAI
import DistrictAuthCore
import DistrictModel
import Foundation
import UIKit
import XCTest

/// What ``PushRegistrar`` records, and what it refuses to do while signed out, over a real
/// ``AppContainer`` whose requests go to a ``FixtureTransport``.
///
/// ⛔ THE STATE IS THE POINT: "registered", "the server refused, with this status" and "APNs
/// refused" must each be readable afterwards, because the shipped failure was all three looking
/// the same. ⚠️ `enableAfterSignIn()` is not called here: it raises the system notification
/// prompt, which a unit test host cannot answer.
@MainActor
final class PushRegistrarStateTests: XCTestCase {
    private var containers: [AppContainer] = []

    override func tearDown() async throws {
        // ⚠️ THE REMEMBERED TOKEN LIVES IN `UserDefaults.standard`: forgotten so no later test
        // finds a token of ours already registered and skips its own register.
        containers.forEach { $0.pushTokens.forgetRegistration() }
        containers = []
        UITestSession.inProcess = nil
        try await super.tearDown()
    }

    // MARK: - The device token's register

    func testARegisterThatLandsReadsRegistered() async throws {
        let transport = FixtureTransport([Self.register: .json(#"{"success":true}"#)])
        let registrar = try await PushRegistrar(container: signedIn(transport))

        registrar.deviceTokenReceived(Self.freshToken())

        await waitUntil(state: "\(registrar.registration)") { registrar.registration == .registered }
        XCTAssertEqual(transport.requested.filter { $0 == "POST \(Self.register)" }.count, 1)
    }

    /// ⚠️ THE STATUS IS KEPT: 429 is the 20/min ceiling, a different remedy from a 401 or a 5xx.
    func testARefusedRegisterKeepsItsStatus() async throws {
        let transport = FixtureTransport([Self.register: .json(#"{"error":"slow down"}"#, status: 429)])
        let registrar = try await PushRegistrar(container: signedIn(transport))

        registrar.deviceTokenReceived(Self.freshToken())

        await waitUntil(state: "\(registrar.registration)") { registrar.registration == .refused(status: 429) }
    }

    /// ⛔ A 200 THAT DOES NOT AFFIRM SUCCESS IS CONTRACT DRIFT, READ AS A REFUSAL, never as
    /// registered: remembering a token the server may not hold leaves push silently off.
    func testA200ThatDoesNotAffirmIsARefusalNotARegistration() async throws {
        let transport = FixtureTransport([Self.register: .json(#"{"success":false}"#)])
        let registrar = try await PushRegistrar(container: signedIn(transport))

        registrar.deviceTokenReceived(Self.freshToken())

        await waitUntil(state: "\(registrar.registration)") { registrar.registration == .refused(status: 200) }
        XCTAssertEqual(PushRegistrar.status(for: .failure(.decoding("drift"))), .refused(status: 200))
    }

    /// ⚠️ AN EMPTY TOKEN SENDS NOTHING AND SAYS NO ATTEMPT, even after a refusal.
    func testAnEmptyTokenSendsNothingAndResetsToNoAttempt() async throws {
        let transport = FixtureTransport([Self.register: .json(#"{"error":"slow down"}"#, status: 429)])
        let registrar = try await PushRegistrar(container: signedIn(transport))
        registrar.deviceTokenReceived(Self.freshToken())
        await waitUntil(state: "\(registrar.registration)") { registrar.registration == .refused(status: 429) }

        registrar.deviceTokenReceived("")

        await waitUntil(state: "\(registrar.registration)") { registrar.registration == .notAttempted }
        XCTAssertEqual(transport.requested.filter { $0 == "POST \(Self.register)" }.count, 1)
    }

    // MARK: - APNs refusing

    /// ⛔ NOT LOG-ONLY: an APNs refusal is readable afterwards, with what APNs said.
    func testAnAPNsRefusalIsRecorded() {
        let registrar = PushRegistrar(container: AppContainer(transport: FixtureTransport()))
        XCTAssertNil(registrar.lastRegistrationFailure)
        XCTAssertEqual(registrar.registration, .notAttempted)
        XCTAssertEqual(registrar.authorization, .notAsked)

        registrar.remoteRegistrationFailed(NoAPSEnvironment())

        XCTAssertEqual(registrar.registration, .apnsRefused)
        XCTAssertEqual(registrar.lastRegistrationFailure, "NoAPSEnvironment()")
    }

    // MARK: - Signed out

    /// ⚠️ A WAKE WITH NO LIVE SESSION ANSWERS `.noData` AND SPENDS NO REQUEST: there is no
    /// session to trust, and a badge read would be a 401.
    func testASilentPushWhileSignedOutReadsNothing() async {
        let transport = FixtureTransport()
        let registrar = PushRegistrar(container: AppContainer(transport: transport))

        let result = await registrar.handleSilentPush()

        XCTAssertEqual(result, .noData)
        XCTAssertFalse(transport.requested.contains { $0.contains("unread-count") })
    }

    /// ⛔ A VOIP TOKEN BEFORE THE SESSION GATE IS HELD, NOT SENT, even with a bearer in hand:
    /// PushKit hands it over at launch, and a register then is a 401 against a 20/min ceiling.
    func testAVoipTokenBeforeSignInIsHeldNotSent() async throws {
        let transport = FixtureTransport([Self.register: .json(#"{"success":true}"#)])
        let container = try await signedIn(transport)
        let registrar = PushRegistrar(container: container)

        registrar.voipTokenReceived(Self.freshToken())
        registrar.voipTokenInvalidated()
        registrar.voipTokenReceived(Self.freshToken())
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(transport.requested.contains("POST \(Self.register)"))
    }

    /// ⛔ THE UNREGISTER GOES OUT, WITH THE BEARER, BEFORE THE SIGN-OUT MOVES ON.
    func testTheSignOutUnregisterIsAwaited() async throws {
        let transport = FixtureTransport([Self.unregister: .json(#"{"success":true}"#)])
        let registrar = try await PushRegistrar(container: signedIn(transport))

        await registrar.unregisterForSignOut()

        XCTAssertTrue(transport.requested.contains("POST \(Self.unregister)"), "\(transport.requested)")
    }

    // MARK: - The tap relay

    /// ⛔ A TAP AT COLD LAUNCH ARRIVES BEFORE THE REGISTRAR: it is buffered, handed over once on
    /// adoption, and not handed over twice.
    func testATapBeforeAdoptionIsBufferedAndHandedOverOnce() {
        let relay = PushTapRelay()
        let registrar = PushRegistrar(container: AppContainer(transport: FixtureTransport()))

        relay.deliver(["type": "message", "threadKey": "contact:c_1"])
        XCTAssertNil(registrar.pendingTapPayload)
        relay.adopt(registrar: registrar)

        XCTAssertEqual(registrar.pendingTapPayload, ["type": "message", "threadKey": "contact:c_1"])
        registrar.pendingTapPayload = nil
        let again = PushRegistrar(container: AppContainer(transport: FixtureTransport()))
        relay.adopt(registrar: again)
        XCTAssertNil(again.pendingTapPayload, "the buffer was emptied by the first adoption")
    }

    func testATapAfterAdoptionGoesStraightThroughAndTheLatestWins() {
        let relay = PushTapRelay()
        let registrar = PushRegistrar(container: AppContainer(transport: FixtureTransport()))
        relay.adopt(registrar: registrar)
        XCTAssertNil(registrar.pendingTapPayload)

        relay.deliver(["type": "call", "callId": "call_1"])
        relay.deliver(["type": "call", "callId": "call_2"])

        XCTAssertEqual(registrar.pendingTapPayload, ["type": "call", "callId": "call_2"])
    }

    /// ⚠️ ONLY STRING KEYS WITH STRING VALUES SURVIVE: APNs nests `aps`, and a number or a null
    /// is not something the router reads.
    func testFlattenKeepsOnlyStringPairs() {
        let userInfo: [AnyHashable: Any] = [
            "type": "message",
            "aps": ["alert": "Hello"],
            "badge": 3,
            "nothing": NSNull(),
            7: "numeric key",
            "": "empty key",
        ]

        XCTAssertEqual(NotificationPresenter.flatten(userInfo), ["type": "message", "": "empty key"])
        XCTAssertEqual(NotificationPresenter.flatten([:]), [:])
    }

    // MARK: - Helpers

    private static let register = "/api/district/devices/register"
    private static let unregister = "/api/district/devices/unregister"

    /// A token no earlier run remembered, so the register is never skipped as already sent.
    private static func freshToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// A container signed in as the snapshot session, once its bearer is available.
    private func signedIn(_ transport: FixtureTransport) async throws -> AppContainer {
        UITestSession.inProcess = ScreenSnapshotTestCase.session
        let container = try AppContainer(
            baseURL: XCTUnwrap(URL(string: "https://push.invalid")),
            microphone: FakeMicrophoneAccess(status: .granted),
            transport: transport
        )
        containers.append(container)
        for _ in 0 ..< 200 {
            if case .available = await container.coordinator.accessToken() {
                return container
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("the session was never adopted")
        return container
    }
}

/// What APNs says on a build with no `aps-environment` entitlement, as far as this test cares.
private struct NoAPSEnvironment: Error {}
