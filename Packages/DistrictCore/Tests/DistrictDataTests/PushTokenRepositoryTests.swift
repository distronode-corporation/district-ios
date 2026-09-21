import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// This installation's push registration, and the memory that decides whether a
/// register is worth sending.
///
/// ⚠️ THE ROUTE PATHS ARE ASSERTED BY STRING, for the same reason
/// `DevicesRepositoryTests` does it: there are TWO `devices` surfaces on this API
/// and they 404 each other. These two live under `/api/district/devices/…` (push
/// registration, behind the default-deny middleware); the account's session list
/// and its revokes live under `/api/auth/native/devices/…` (a public proxy
/// prefix). A path typo would present as a broken client rather than a wrong URL.
///
/// ⛔ THE `platform` KEY IS ASSERTED ON THE BYTES, NOT INFERRED. The route's
/// schema DEFAULTS it to `"android"`, so an omitted key is accepted and silently
/// mislabels every row this client writes — and the server's push sender chooses the
/// APNs payload from exactly that column. The failure is invisible from here: the
/// registration succeeds and no push ever arrives.
final class PushTokenRepositoryTests: XCTestCase {
    // MARK: - Registering

    func testRegisteringPostsTheTokenAndThePlatformAndRemembersIt() async {
        let memory = RecordingPushTokenMemory()
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await PushTokenRepository(client: .repositoryTest(transport), memory: memory)
            .register(token: "apns-token-1")

        XCTAssertEqual(result.successOnly, .registered)
        XCTAssertEqual(transport.requests.first?.method, .post)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/devices/register"
        )
        // ⛔ BOTH KEYS, AND `platform` IS THE ONE THAT MATTERS. See the ⛔ on the class.
        XCTAssertEqual(transport.bodies.first, #"{"platform":"ios","token":"apns-token-1"}"#)
        XCTAssertEqual(memory.lastRegisteredToken(), "apns-token-1")
    }

    /// ⛔ THE SKIP IS KEYED ON THE TOKEN VALUE, NOT ON A "have we registered" FLAG.
    /// That is the whole difference between this and the cache the Kotlin client
    /// deliberately refuses: a rotated token is a different string and is never
    /// skipped (see the test below), so the optimisation cannot outlive the case
    /// it optimises.
    func testRegisteringTheSameTokenTwiceSendsOneRequest() async {
        let memory = RecordingPushTokenMemory(token: "apns-token-1")
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await PushTokenRepository(client: .repositoryTest(transport), memory: memory)
            .register(token: "apns-token-1")

        XCTAssertEqual(result.successOnly, .alreadyRegistered)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    /// ⛔ A ROTATION IS THE CASE THE SKIP MUST NOT SWALLOW. APNs reissues a device
    /// token on its own schedule (a restore to a new device, a reinstall), and a
    /// missed rotation is silent: our server keeps accepting the old token and
    /// APNs keeps rejecting it, so push stops with nothing reporting a fault.
    func testARotatedTokenIsRegisteredRatherThanSkipped() async {
        let memory = RecordingPushTokenMemory(token: "apns-token-1")
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await PushTokenRepository(client: .repositoryTest(transport), memory: memory)
            .register(token: "apns-token-2")

        XCTAssertEqual(result.successOnly, .registered)
        XCTAssertEqual(memory.lastRegisteredToken(), "apns-token-2")
    }

    /// ⚠️ AN EMPTY TOKEN IS AN ORDINARY STATE, NOT A FAULT, AND IT COSTS NO
    /// REQUEST. Sending one spends the 20/min ceiling to be told 400, and a client
    /// that read that 400 as "registration failed" would retry it.
    func testAnEmptyTokenIsASuccessThatSendsNothing() async {
        let memory = RecordingPushTokenMemory()
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await PushTokenRepository(client: .repositoryTest(transport), memory: memory)
            .register(token: "")

        XCTAssertEqual(result.successOnly, .noTokenToRegister)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertNil(memory.lastRegisteredToken())
    }

    /// ⛔ THE ENVELOPE CHECK IS NOT REDUNDANT WITH THE DTO'S REQUIRED FIELD. A
    /// required field rejects `{}`; it does not reject a well-formed body that
    /// says `success: false`, which is what this route's own catch branch produces
    /// on a 200 once the headers are written.
    ///
    /// ⛔ AND THE TOKEN MUST NOT BE REMEMBERED, or the next register would skip and
    /// push would stay off for the life of the install.
    func testARegisterThatDoesNotAffirmSuccessIsADecodeFailureAndRemembersNothing() async {
        let memory = RecordingPushTokenMemory()
        let transport = RepositoryTransport(json: #"{"success":false}"#)

        let result = await PushTokenRepository(client: .repositoryTest(transport), memory: memory)
            .register(token: "apns-token-1")

        XCTAssertEqual(result.failureOnly, .decoding("PushRegisterResponse did not affirm success=true"))
        XCTAssertNil(memory.lastRegisteredToken())
    }

    /// ⚠️ A 401 IS THE SHAPE A REGISTER SENT TOO EARLY TAKES — before a sign-in
    /// there is no bearer — which is exactly why `PushRegistrar` triggers on the
    /// session gate reaching signed-in rather than at launch. It is carried
    /// through as a failure and remembers nothing.
    func testAnUnauthorizedRegisterFailsAndRemembersNothing() async {
        let memory = RecordingPushTokenMemory()
        let transport = RepositoryTransport(json: #"{"error":"Unauthorized"}"#, status: 401)

        let result = await PushTokenRepository(client: .repositoryTest(transport), memory: memory)
            .register(token: "apns-token-1")

        XCTAssertEqual(result.failureOnly?.httpStatus, 401)
        XCTAssertEqual(result.failureOnly?.isUnauthorized, true)
        XCTAssertNil(memory.lastRegisteredToken())
    }

    /// ⚠️ A REQUEST THAT NEVER LEFT THE DEVICE IS NOT A REFUSAL. Push is a
    /// courtesy channel, so this is reported and dropped rather than surfaced —
    /// but it must not be recorded as a registration.
    func testATransportFailureOnRegisterRemembersNothing() async {
        let memory = RecordingPushTokenMemory()
        let client = ApiClient(transport: FailingRepositoryTransport(), accessToken: { "session-token" })

        let result = await PushTokenRepository(client: client, memory: memory).register(token: "apns-token-1")

        // ⚠️ THE CASE, NOT THE SENTENCE. `ApiClient` builds the string with
        // `String(describing:)` on whatever the stack threw, so pinning it would
        // pin the name of a private error type here rather than the behaviour.
        guard case .transport = result.failureOnly else {
            return XCTFail("expected a transport failure, got \(String(describing: result.failureOnly))")
        }
        XCTAssertNil(memory.lastRegisteredToken())
    }

    // MARK: - Registering the PushKit token

    /// ⛔ THE `kind` KEY IS ASSERTED ON THE BYTES AND IT IS THE WHOLE DIFFERENCE
    /// BETWEEN THE TWO REGISTERS. Without it the route's default writes an `fcm`
    /// row, so the PushKit token would land in the column the ALERT sender reads
    /// and the phone would be reachable for neither: alerts sent to a VoIP token
    /// are not delivered, and VoIP payloads sent to an alert token are rejected.
    func testRegisteringTheVoipTokenSendsTheKindKeyAndRemembersItSeparately() async {
        let memory = RecordingPushTokenMemory(token: "apns-token-1")
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await PushTokenRepository(client: .repositoryTest(transport), memory: memory)
            .registerVoip(token: "voip-token-1")

        XCTAssertEqual(result.successOnly, .registered)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/devices/register"
        )
        XCTAssertEqual(
            transport.bodies.first,
            #"{"kind":"voip","platform":"ios","token":"voip-token-1"}"#
        )
        XCTAssertEqual(memory.lastRegisteredVoipToken(), "voip-token-1")
        // ⛔ AND THE ALERT TOKEN IS UNTOUCHED. One handset holds both; a register
        // that moved the other one is how a device stops receiving notifications
        // the moment it becomes able to ring.
        XCTAssertEqual(memory.lastRegisteredToken(), "apns-token-1")
    }

    /// ⛔ THE ALERT REGISTER'S BYTES ARE UNCHANGED BY THE KIND PARAMETER, WHICH IS
    /// WHY `PushTokenKind.alert` OMITS THE KEY RATHER THAN SENDING `"fcm"`. The
    /// route defaults `kind` to the alert value, so an absent key is already
    /// right; `platform` is the opposite case (its default is `"android"`, which
    /// is wrong for every row this client writes) and it is sent explicitly.
    func testTheAlertRegisterStillSendsNoKindKeyAtAll() async {
        let memory = RecordingPushTokenMemory()
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        _ = await PushTokenRepository(client: .repositoryTest(transport), memory: memory)
            .register(token: "apns-token-1")

        XCTAssertEqual(transport.bodies.first, #"{"platform":"ios","token":"apns-token-1"}"#)
    }

    /// ⛔ THE SKIP IS KEYED ON THE VOIP SLOT, NOT THE ALERT ONE. A shared
    /// remembered value would skip the VoIP register whenever the alert token was
    /// unchanged, and the phone would stop ringing with nothing reporting it.
    func testTheVoipSkipIsKeyedOnItsOwnRememberedTokenRatherThanTheAlertOne() async {
        let memory = RecordingPushTokenMemory(token: "voip-token-1", voipToken: nil)
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await PushTokenRepository(client: .repositoryTest(transport), memory: memory)
            .registerVoip(token: "voip-token-1")

        XCTAssertEqual(result.successOnly, .registered)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testRegisteringTheSameVoipTokenTwiceSendsOneRequest() async {
        let memory = RecordingPushTokenMemory(voipToken: "voip-token-1")
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await PushTokenRepository(client: .repositoryTest(transport), memory: memory)
            .registerVoip(token: "voip-token-1")

        XCTAssertEqual(result.successOnly, .alreadyRegistered)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    /// ⚠️ THE SIMULATOR HAS NO PUSH SERVICE AND ISSUES NO PushKit CREDENTIAL, so
    /// an empty VoIP token is an ordinary state rather than a fault, exactly as it
    /// is for the alert token.
    func testAnEmptyVoipTokenIsASuccessThatSendsNothing() async {
        let memory = RecordingPushTokenMemory()
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await PushTokenRepository(client: .repositoryTest(transport), memory: memory)
            .registerVoip(token: "")

        XCTAssertEqual(result.successOnly, .noTokenToRegister)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertNil(memory.lastRegisteredVoipToken())
    }

    /// ⛔ AND A VOIP REGISTER THAT DID NOT AFFIRM REMEMBERS NOTHING, or the next
    /// one would skip against a row the server may not hold and the phone would
    /// never ring again on this install.
    func testAVoipRegisterThatDoesNotAffirmSuccessRemembersNothing() async {
        let memory = RecordingPushTokenMemory()
        let transport = RepositoryTransport(json: #"{"success":false}"#)

        let result = await PushTokenRepository(client: .repositoryTest(transport), memory: memory)
            .registerVoip(token: "voip-token-1")

        XCTAssertEqual(result.failureOnly, .decoding("PushRegisterResponse did not affirm success=true"))
        XCTAssertNil(memory.lastRegisteredVoipToken())
    }

    /// ⚠️ A 401 IS THE SHAPE A VOIP REGISTER TAKES WHEN IT RUNS TOO EARLY, and
    /// unlike the alert token that is the DEFAULT timing rather than a mistake:
    /// PushKit issues its credential at launch, before any sign-in. `PushRegistrar`
    /// holds the token until the session gate resolves for exactly this reason.
    func testAnUnauthorizedVoipRegisterFailsAndRemembersNothing() async {
        let memory = RecordingPushTokenMemory()
        let transport = RepositoryTransport(json: #"{"error":"Unauthorized"}"#, status: 401)

        let result = await PushTokenRepository(client: .repositoryTest(transport), memory: memory)
            .registerVoip(token: "voip-token-1")

        XCTAssertEqual(result.failureOnly?.httpStatus, 401)
        XCTAssertNil(memory.lastRegisteredVoipToken())
    }

    // MARK: - Unregistering

    func testUnregisteringPostsAnEmptyObjectToThePushRoute() async {
        let memory = RecordingPushTokenMemory(token: "apns-token-1")
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await PushTokenRepository(client: .repositoryTest(transport), memory: memory).unregister()

        XCTAssertNil(result.failureOnly)
        XCTAssertEqual(transport.requests.first?.method, .post)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/devices/unregister"
        )
        XCTAssertEqual(transport.bodies.first, "{}")
    }

    /// ⛔ THE MEMORY IS CLEARED EVEN WHEN THE SERVER REFUSED, AND THE ASYMMETRY IS
    /// DELIBERATE. After an attempted unregister this client cannot claim the
    /// server still holds its token; recording "we do not know" as "still
    /// registered" would make the next register skip and leave push off with
    /// nothing reporting it. Clearing an entry that turns out to have been fine
    /// costs exactly one request.
    ///
    /// ⛔ AND IT FORGETS **BOTH**, because one request withdrew both. The route
    /// runs `deleteMany` scoped on `{userId, deviceId}` and names no kind, so a
    /// remembered VoIP token surviving here would make the next `registerVoip`
    /// skip against a row the server no longer has.
    func testAFailedUnregisterStillForgetsBothRememberedTokens() async {
        let memory = RecordingPushTokenMemory(token: "apns-token-1", voipToken: "voip-token-1")
        let transport = RepositoryTransport(json: #"{"error":"server_error"}"#, status: 500)

        let result = await PushTokenRepository(client: .repositoryTest(transport), memory: memory).unregister()

        XCTAssertEqual(result.failureOnly?.httpStatus, 500)
        XCTAssertNil(memory.lastRegisteredToken())
        XCTAssertNil(memory.lastRegisteredVoipToken())
    }

    /// ⛔ A 200 THAT DOES NOT AFFIRM IS "we do not know", NOT "push is off". The
    /// row may still be live, and this handset may still receive another person's
    /// notifications after they sign in on it.
    func testAnUnregisterThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let memory = RecordingPushTokenMemory(token: "apns-token-1")
        let transport = RepositoryTransport(json: #"{"success":false}"#)

        let result = await PushTokenRepository(client: .repositoryTest(transport), memory: memory).unregister()

        XCTAssertEqual(result.failureOnly, .decoding("PushUnregisterResponse did not affirm success=true"))
    }

    // MARK: - Forgetting, with no server involved

    /// ⛔ THE PATH FOR A SESSION THE SERVER ENDED. Nothing local ran, so nothing
    /// unregistered; without this the next account to sign in on the handset would
    /// find its own token remembered, skip the register, and never claim the
    /// installation row — which is the server's UPSERT KEY, so the previous
    /// account would keep receiving this device's notifications.
    ///
    /// ⛔ BOTH SLOTS, AND THE VOIP ONE IS THE EXPENSIVE ONE TO GET WRONG. A VoIP
    /// token left remembered across a server-ended session would make the next
    /// account's `registerVoip` skip, and the PREVIOUS account's calls would keep
    /// ringing a handset somebody else is now holding.
    func testForgettingClearsBothSlotsWithoutASingleRequest() {
        let memory = RecordingPushTokenMemory(token: "apns-token-1", voipToken: "voip-token-1")
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        PushTokenRepository(client: .repositoryTest(transport), memory: memory).forgetRegistration()

        XCTAssertNil(memory.lastRegisteredToken())
        XCTAssertNil(memory.lastRegisteredVoipToken())
        XCTAssertTrue(transport.requests.isEmpty)
    }
}

/// The ``PushTokenMemory`` double.
///
/// ⚠️ A CLASS BECAUSE THE PROTOCOL'S WRITES ARE NON-MUTATING, which is itself a
/// decision rather than an accident: the real implementation is `UserDefaults`,
/// which is a reference, and a `mutating` requirement would force every holder of
/// the repository to be `var`.
///
/// ⛔ TWO SLOTS, NOT ONE, AND THE SEPARATION IS WHAT SEVERAL TESTS BELOW ASSERT.
/// A double that stored both tokens in one field would make every "the other kind
/// was not disturbed" test pass for the wrong reason.
private final class RecordingPushTokenMemory: PushTokenMemory, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private var voipToken: String?

    init(token: String? = nil, voipToken: String? = nil) {
        self.token = token
        self.voipToken = voipToken
    }

    func lastRegisteredToken() -> String? {
        lock.withLock { token }
    }

    func rememberRegisteredToken(_ token: String) {
        lock.withLock { self.token = token }
    }

    func forgetRegisteredToken() {
        lock.withLock { token = nil }
    }

    func lastRegisteredVoipToken() -> String? {
        lock.withLock { voipToken }
    }

    func rememberRegisteredVoipToken(_ token: String) {
        lock.withLock { voipToken = token }
    }

    func forgetRegisteredVoipToken() {
        lock.withLock { voipToken = nil }
    }
}

/// A transport whose request never leaves the device.
///
/// ⚠️ SEPARATE FROM ``RepositoryTransport`` BECAUSE THAT ONE ANSWERS A RESPONSE.
/// "The server refused" and "the request was never sent" are different facts, and
/// only the second one reaches ``ApiError/transport(_:)``.
private struct FailingRepositoryTransport: HTTPTransport {
    struct Offline: Error {}

    func send(_ request: HTTPRequest, followRedirects: Bool) async throws -> HTTPResponse {
        _ = request
        _ = followRedirects
        throw Offline()
    }
}
