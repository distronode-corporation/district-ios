import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The account's device list and its two revokes.
///
/// ⛔ THESE ARE NOT ORDINARY READS AND WRITES, WHICH IS WHY THE ASSERTIONS ARE
/// ABOUT MEANING RATHER THAN DECODING. The list is what someone consults after
/// losing a phone, so an empty one must not read as a failure and a failure must
/// not read as an empty one. The writes end sessions, one of which can be this
/// device's own, so a `revoked: 0` has to survive as a distinct outcome instead
/// of being flattened into either success or error.
///
/// ⚠️ THE ROUTE PATHS ARE ASSERTED BY STRING because these three live under
/// `/api/auth/native/…` while every district route lives under `/api/district/…`
/// — and there is a second, unrelated `devices` surface at
/// `/api/district/devices/{register,unregister}` for push. The two 404 each
/// other, and a path typo would present as a broken client rather than as a
/// wrong URL.
final class DevicesRepositoryTests: XCTestCase {
    // MARK: - The list

    func testListingDevicesGetsTheNativeDeviceRouteAndAnswersTheRows() async {
        let transport = RepositoryTransport(json: Bodies.devices(ids: ["device-a", "device-b"]))

        let result = await DevicesRepository(client: .repositoryTest(transport)).list()

        XCTAssertEqual(result.successOnly?.map(\.deviceId), ["device-a", "device-b"])
        XCTAssertEqual(transport.requests.first?.method, .get)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/auth/native/devices"
        )
    }

    /// ⛔ AN EMPTY LIST IS A SUCCESS AND MUST STAY ONE. The route filters on
    /// `rotatedAt: null`, so a chain caught mid-refresh is briefly invisible —
    /// which on a single-device account is an empty list arriving on a perfectly
    /// good session. Mapping it to a failure would tell someone they had been
    /// signed out while they were not.
    func testAnEmptyDeviceListIsASuccessRatherThanAFailure() async {
        let transport = RepositoryTransport(json: #"{"success":true,"devices":[]}"#)

        let result = await DevicesRepository(client: .repositoryTest(transport)).list()

        XCTAssertEqual(result.successOnly?.isEmpty, true)
        XCTAssertNil(result.failureOnly)
    }

    /// ⛔ THE ENVELOPE CHECK IS NOT REDUNDANT WITH THE DTO'S REQUIRED FIELDS. A
    /// required field rejects `{}`; it does not reject a well-formed body that
    /// says `success: false`, which is what this route's catch branch produces on
    /// a 200 once the headers are written. Without this, "we could not look"
    /// would render as "you have no devices".
    func testADeviceListThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false,"devices":[]}"#)

        let result = await DevicesRepository(client: .repositoryTest(transport)).list()

        XCTAssertEqual(result.failureOnly, .decoding("DevicesResponse did not affirm success=true"))
    }

    /// ⚠️ BOTH OPTIONALS ARE NULL ON THE WIRE RATHER THAN ABSENT, AND THE
    /// REPOSITORY MUST CARRY THAT THROUGH. This is the install that signed in and
    /// has not yet rotated: no name because none was sent, no `lastUsedAt`
    /// because nothing has stamped it. Every session looks like this for its
    /// first ten minutes.
    func testANeverRefreshedDeviceDecodesWithBothOptionalsNil() async {
        let transport = RepositoryTransport(json: Bodies.devices(ids: ["device-fresh"], named: false))

        let result = await DevicesRepository(client: .repositoryTest(transport)).list()

        let device = result.successOnly?.first
        XCTAssertEqual(device?.deviceId, "device-fresh")
        XCTAssertNil(device?.deviceName)
        XCTAssertNil(device?.lastUsedAt)
        XCTAssertEqual(device?.platform, "ios")
    }

    /// ⛔ THE STATUS SURVIVES AND THE ROUTE'S SENTENCE DOES NOT, AND THAT IS PINNED
    /// HERE BECAUSE IT IS SURPRISING RATHER THAN BECAUSE IT IS RIGHT. These four
    /// `/api/auth/native/…` routes answer `{error: "<code>", message:
    /// "<sentence>"}`, splitting the two across two keys; every district route
    /// answers `{success:false, error: "<sentence>"}` and puts the code in `code`.
    /// ``ApiErrorEnvelope`` models `success`, `error` and `code` — no `message` —
    /// so what reaches ``ApiError/http(status:message:)`` from here is the machine
    /// code, `"rate_limited"`, not the sentence a user could read. The Kotlin
    /// client's envelope has exactly the same three fields and behaves the same
    /// way, so this is a shared shape rather than an iOS divergence, and widening
    /// it is a change to every route's failure path rather than to this one.
    /// ⚠️ IT IS SURVIVABLE ON THIS SCREEN because the headline
    /// ("Could not list your devices") carries the meaning, and 429 maps to a
    /// retry, which is the correct offer. It would not be survivable as the only
    /// sentence.
    ///
    /// ⚠️ Rate limited at 30/min PER ACCOUNT, sized for a settings screen.
    func testARateLimitedListKeepsTheStatusEvenThoughTheSentenceIsLost() async {
        let transport = RepositoryTransport(
            json: #"{"error":"rate_limited","message":"Too many requests. Please try again shortly."}"#,
            status: 429
        )

        let result = await DevicesRepository(client: .repositoryTest(transport)).list()

        XCTAssertEqual(result.failureOnly, .http(status: 429, message: "rate_limited"))
        XCTAssertEqual(result.failureOnly?.httpStatus, 429)
    }

    // MARK: - Revoking one device

    func testRevokingOneDevicePostsTheIdAndAnswersTheCount() async {
        let transport = RepositoryTransport(json: #"{"success":true,"revoked":1}"#)

        let result = await DevicesRepository(client: .repositoryTest(transport))
            .revoke(deviceId: "device-12345678")

        XCTAssertEqual(result.successOnly, 1)
        XCTAssertEqual(transport.requests.first?.method, .post)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/auth/native/devices/revoke"
        )
        // ⛔ THE ID GOES IN THE BODY AND THE ACCOUNT COMES FROM THE BEARER. The
        // route filters on `{userId, deviceId}`, so a caller can only ever reach
        // rows they own; a client that sent an account identifier here would be
        // offering the server a scope the server refuses to take.
        XCTAssertEqual(transport.bodies.first, #"{"deviceId":"device-12345678"}"#)
    }

    /// ⛔ ZERO IS A SUCCESS CARRYING ZERO, NOT A FAILURE AND NOT A BARE SUCCESS.
    /// The route answers it for a device id that is not yours — deliberately, so
    /// it cannot be used as an oracle over an opaque id space — and equally for a
    /// row another device already revoked or a chain that rotated between the
    /// list read and the tap. Promoting it to an error would report a fault that
    /// did not happen; discarding the count would claim a revocation that did not
    /// happen either.
    func testRevokingNothingIsASuccessThatStillReportsZero() async {
        let transport = RepositoryTransport(json: #"{"success":true,"revoked":0}"#)

        let result = await DevicesRepository(client: .repositoryTest(transport))
            .revoke(deviceId: "device-not-mine")

        XCTAssertEqual(result.successOnly, 0)
        XCTAssertNil(result.failureOnly)
    }

    /// ⛔ A THROWN WRITE IS NOT "nothing to revoke", AND THE TWO ARE ONE KEY APART
    /// ON THE WIRE. The route answers 500 here and `{success:true, revoked:0}`
    /// there; the session may still be live in the first case, so a client that
    /// folded it into success would tell someone their lost phone was signed out
    /// when it was not.
    ///
    /// ⚠️ THE MESSAGE IS THE CODE RATHER THAN THE SENTENCE, for the reason the
    /// rate-limit test above sets out. Harmless on a 5xx specifically, because
    /// ``FailureText`` deliberately DISCARDS a 5xx body — these routes return raw
    /// exception text on some siblings and it must never reach a screen.
    func testAFailedRevokeWriteIsAFailureRatherThanAZeroCount() async {
        let transport = RepositoryTransport(
            json: #"{"error":"server_error","message":"Could not sign out that device."}"#,
            status: 500
        )

        let result = await DevicesRepository(client: .repositoryTest(transport))
            .revoke(deviceId: "device-12345678")

        XCTAssertEqual(result.failureOnly?.httpStatus, 500)
        XCTAssertNil(result.successOnly)
    }

    func testARevokeThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false,"revoked":1}"#)

        let result = await DevicesRepository(client: .repositoryTest(transport))
            .revoke(deviceId: "device-12345678")

        XCTAssertEqual(result.failureOnly, .decoding("DeviceRevokeResponse did not affirm success=true"))
    }

    // MARK: - Revoking everything

    /// ⚠️ AN EMPTY OBJECT GOES ON THE WIRE EVEN THOUGH THE ROUTE PARSES NOTHING.
    /// It is a parity choice with the Kotlin client, where OkHttp forced a body
    /// on a POST: the two clients put identical bytes on the wire for the same
    /// call, so a capture from one is readable as the other.
    func testRevokingEverythingPostsAnEmptyObjectAndAnswersTheCount() async {
        let transport = RepositoryTransport(json: #"{"success":true,"revoked":2}"#)

        let result = await DevicesRepository(client: .repositoryTest(transport)).revokeAll()

        XCTAssertEqual(result.successOnly, 2)
        XCTAssertEqual(transport.requests.first?.method, .post)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/auth/native/revoke-all"
        )
        XCTAssertEqual(transport.bodies.first, "{}")
    }

    /// ⚠️ ZERO IS LEGITIMATE HERE TOO — a second press, after the first revoked
    /// everything. It still means this device is signed out, because the server's
    /// "all" does not spare the caller; that consequence belongs to the screen,
    /// and this layer only reports the count.
    func testRevokingEverythingTwiceStillSucceedsWithZero() async {
        let transport = RepositoryTransport(json: #"{"success":true,"revoked":0}"#)

        let result = await DevicesRepository(client: .repositoryTest(transport)).revokeAll()

        XCTAssertEqual(result.successOnly, 0)
        XCTAssertNil(result.failureOnly)
    }

    func testARevokeAllThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false,"revoked":2}"#)

        let result = await DevicesRepository(client: .repositoryTest(transport)).revokeAll()

        XCTAssertEqual(result.failureOnly, .decoding("DeviceRevokeAllResponse did not affirm success=true"))
    }
}

private extension Bodies {
    /// The device list's envelope, with one row per id.
    ///
    /// ⚠️ `named: false` PRODUCES THE FRESHLY-SIGNED-IN SHAPE, with `deviceName`
    /// and `lastUsedAt` both explicitly null rather than omitted — which is what
    /// the route sends, because it serialises the Prisma selection whole.
    static func devices(ids: [String], named: Bool = true) -> String {
        let rows = ids.map { device(id: $0, named: named) }.joined(separator: ",")
        return #"{"success":true,"devices":[\#(rows)]}"#
    }

    static func device(id: String, named: Bool) -> String {
        let name = named ? #""Ada's iPhone""# : "null"
        let lastUsed = named ? #""2026-09-06T09:41:00.000Z""# : "null"
        return #"""
        {"deviceId":"\#(id)","deviceName":\#(name),"platform":"ios",
         "lastUsedAt":\#(lastUsed),"createdAt":"2026-09-06T09:00:00.000Z"}
        """#
    }
}
