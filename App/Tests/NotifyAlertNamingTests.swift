@testable import DistrictAI
import DistrictNetwork
import Foundation
import Security
import XCTest

/// The notification service extension's decisions (3.2), and the Keychain groups that keep
/// the session out of its reach. The extension compiles `App/NotifyShared` too; these tests
/// hold that source here, in the app's bundle.
final class NotifyAlertNamingTests: XCTestCase {
    private let target = MessageAlertTarget(workspaceId: "ws_1", messageId: "msg_1")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Keychain groups

    func testAGroupNeedsAResolvedTeamPrefix() {
        XCTAssertEqual(
            KeychainAccessGroups.group(KeychainAccessGroups.privateSuffix, prefix: "R935BA6767."),
            "R935BA6767.com.distronode.district"
        )
        XCTAssertEqual(
            KeychainAccessGroups.group(KeychainAccessGroups.notifySuffix, prefix: "R935BA6767."),
            "R935BA6767.com.distronode.district.notify"
        )
        for unresolved in [nil, "", ".", "R935BA6767", "$(AppIdentifierPrefix)"] {
            XCTAssertNil(
                KeychainAccessGroups.group(KeychainAccessGroups.privateSuffix, prefix: unresolved),
                String(describing: unresolved)
            )
        }
    }

    /// ⛔ THE SESSION NAMES THE PRIVATE GROUP ON EVERY QUERY, and an unsigned build names none.
    func testTheSessionStoreNamesThePrivateGroup() {
        let signed = KeychainTokenStore(accessGroup: "R935BA6767.com.distronode.district")
        XCTAssertEqual(
            signed.query(account: "native-session")[kSecAttrAccessGroup as String] as? String,
            "R935BA6767.com.distronode.district"
        )
        let unsigned = KeychainTokenStore(accessGroup: nil)
        XCTAssertNil(unsigned.query(account: "native-session")[kSecAttrAccessGroup as String])
    }

    /// ⛔ THE NOTIFY TOKEN NAMES THE SHARED GROUP, and with none it touches nothing at all:
    /// an unnamed write would land in the app's private group.
    func testTheNotifyStoreNamesTheSharedGroupOrNothing() throws {
        let signed = NotifyTokenKeychain(accessGroup: "R935BA6767.com.distronode.district.notify")
        let query = try XCTUnwrap(signed.query())
        XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, "R935BA6767.com.distronode.district.notify")
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)

        let unsigned = NotifyTokenKeychain(accessGroup: nil)
        XCTAssertNil(unsigned.query())
        XCTAssertNil(try unsigned.read())
        XCTAssertNoThrow(try unsigned.clear())
        XCTAssertThrowsError(try unsigned.write(NotifyToken(token: "t", expiresAt: now)))
    }

    /// ⛔ THE ORDER IS THE RULE: the app's private group first, the shared group second, and
    /// the extension entitled to the shared group alone. Read from the generated files
    /// project.yml writes, which are what a signature is checked against.
    func testTheEntitlementsListThePrivateGroupFirstAndTheExtensionOnlyTheShared() throws {
        let app = try Self.entitlements("App/DistrictAI.entitlements")
        XCTAssertEqual(app["keychain-access-groups"] as? [String], [
            "$(AppIdentifierPrefix)com.distronode.district",
            "$(AppIdentifierPrefix)com.distronode.district.notify",
        ])
        XCTAssertEqual(app["com.apple.developer.usernotifications.time-sensitive"] as? Bool, true)
        let extensionGroups = try Self.entitlements(
            "NotificationService/DistrictAINotificationService.entitlements"
        )["keychain-access-groups"] as? [String]
        XCTAssertEqual(extensionGroups, ["$(AppIdentifierPrefix)com.distronode.district.notify"])
    }

    /// The round-2 contract: mint when missing, expired, or within seven days of expiry.
    func testTheTokenIsRenewedWhenMissingExpiredOrWithinSevenDays() {
        let day: TimeInterval = 24 * 60 * 60
        XCTAssertTrue(NotifyToken.needsRenewal(nil, at: now))
        XCTAssertTrue(NotifyToken.needsRenewal(NotifyToken(token: "t", expiresAt: now), at: now))
        XCTAssertTrue(NotifyToken.needsRenewal(NotifyToken(token: "", expiresAt: now + 20 * day), at: now))
        XCTAssertTrue(NotifyToken.needsRenewal(NotifyToken(token: "t", expiresAt: now + 7 * day), at: now))
        XCTAssertFalse(NotifyToken.needsRenewal(NotifyToken(token: "t", expiresAt: now + 8 * day), at: now))
    }

    // MARK: - Which alerts

    func testTheCategoryIsTheServersAndTheAppsOwn() {
        XCTAssertEqual(MessageAlertNaming.category, DistrictNotificationCategory.message)
    }

    func testOnlyAMessageAlertWithBothIdsIsNamed() {
        let payload = ["type": "message", "workspaceId": "ws_1", "messageId": "msg_1"]
        XCTAssertEqual(MessageAlertNaming.target(categoryIdentifier: "district.message", payload: payload), target)
        // The payload's own category when `aps.category` did not reach the content.
        XCTAssertEqual(
            MessageAlertNaming.target(
                categoryIdentifier: "",
                payload: payload.merging(["category": "district.message"]) { _, new in new }
            ),
            target
        )
        XCTAssertNil(MessageAlertNaming.target(categoryIdentifier: "", payload: payload))
        XCTAssertNil(MessageAlertNaming.target(categoryIdentifier: "district.incoming_call", payload: payload))
        XCTAssertNil(MessageAlertNaming.target(
            categoryIdentifier: "district.message",
            payload: ["workspaceId": "ws_1"]
        ))
        XCTAssertNil(MessageAlertNaming.target(
            categoryIdentifier: "district.message",
            payload: ["workspaceId": "", "messageId": "msg_1"]
        ))
    }

    // MARK: - The name, or the alert as sent

    func testALiveTokenAndANameGiveTheName() async {
        let fetcher = FakeFetcher(answer: .success("  Avery Contract \n"))
        let name = await MessageAlertNaming.senderName(
            of: target, tokens: FakeTokens(.success(Self.live)), fetcher: fetcher, now: now
        )

        XCTAssertEqual(name, "Avery Contract")
        XCTAssertEqual(fetcher.asked, [Ask(target: target, token: "notify-jws")])
    }

    /// ⛔ EVERY FAILURE IS THE ALERT AS SENT, AND NONE OF THEM ASKS TWICE.
    func testEveryFailureLeavesTheAlertAsSent() async {
        let expired = NotifyToken(token: "notify-jws", expiresAt: now)
        let locked = NotifyTokenKeychainError.status(errSecInteractionNotAllowed)
        let refused = URLError(.userAuthenticationRequired)
        let live = FakeTokens(.success(Self.live))
        let cases: [Failure] = [
            Failure(
                label: "no token",
                tokens: FakeTokens(.success(nil)),
                fetcher: FakeFetcher(answer: .success("Avery"))
            ),
            Failure(
                label: "before the first unlock",
                tokens: FakeTokens(.failure(locked)),
                fetcher: FakeFetcher(answer: .success("Avery"))
            ),
            Failure(
                label: "an expired token",
                tokens: FakeTokens(.success(expired)),
                fetcher: FakeFetcher(answer: .success("Avery"))
            ),
            Failure(label: "a refusal", tokens: live, fetcher: FakeFetcher(answer: .failure(refused))),
            Failure(label: "no named contact", tokens: live, fetcher: FakeFetcher(answer: .success(nil))),
            Failure(label: "a blank name", tokens: live, fetcher: FakeFetcher(answer: .success("   "))),
        ]
        for failure in cases {
            let name = await MessageAlertNaming.senderName(
                of: target, tokens: failure.tokens, fetcher: failure.fetcher, now: now
            )
            XCTAssertNil(name, failure.label)
            XCTAssertLessThanOrEqual(failure.fetcher.asked.count, 1, failure.label)
        }
    }

    /// ⛔ THE BUDGET ENDS THE WAIT: a server that does not answer in time leaves the alert.
    func testNoAnswerInsideTheBudgetIsTheAlertAsSent() async {
        let fetcher = FakeFetcher(answer: .success("Avery"), delay: .seconds(30))
        let started = ContinuousClock.now

        let name = await MessageAlertNaming.senderName(
            of: target, tokens: FakeTokens(.success(Self.live)), fetcher: fetcher, now: now, budget: .milliseconds(50)
        )

        XCTAssertNil(name)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }

    func testTheExtensionsBudgetIsFiveSeconds() {
        XCTAssertEqual(MessageAlertNaming.budget, .seconds(5))
    }

    // MARK: - The request

    /// ⛔ ONE GET, BEARING THE NOTIFY TOKEN AND NOTHING ELSE, for the alert's own ids.
    func testTheFetcherAsksTheSenderRouteWithTheNotifyToken() async throws {
        let transport = SenderTransport(status: 200, body: #"{"success":true,"name":"Avery Contract"}"#)
        let rejected = RejectedLog()
        let fetcher = NotifyReadSenderNameFetcher(transport: transport, rejected: rejected.record)

        let name = try await fetcher.senderName(of: target, token: "notify-jws")

        XCTAssertEqual(name, "Avery Contract")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.url.host, "www.distronode.com")
        XCTAssertEqual(request.url.path, "/api/district/messages/msg_1/sender")
        XCTAssertEqual(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.query, "workspaceId=ws_1")
        XCTAssertEqual(request.headers["Authorization"], "Bearer notify-jws")
        XCTAssertEqual(rejected.tokens, [])
    }

    func testANullOrBlankNameIsNoName() async throws {
        for body in [#"{"success":true,"name":null}"#, #"{"success":true,"name":"  "}"#] {
            let fetcher = NotifyReadSenderNameFetcher(
                transport: SenderTransport(status: 200, body: body),
                rejected: RejectedLog().record
            )
            let name = try await fetcher.senderName(of: target, token: "notify-jws")
            XCTAssertNil(name, body)
        }
    }

    /// ⛔ A 401 IS REPORTED WITH ITS TOKEN, ONCE, AND NOT RETRIED; any other refusal forgets nothing.
    func testA401ReportsTheTokenAndNothingElseDoes() async {
        for (status, reported) in [(401, ["notify-jws"]), (404, []), (403, []), (500, [])] {
            let transport = SenderTransport(status: status, body: #"{"success":false,"error":"no"}"#)
            let rejected = RejectedLog()
            let fetcher = NotifyReadSenderNameFetcher(transport: transport, rejected: rejected.record)
            do {
                _ = try await fetcher.senderName(of: target, token: "notify-jws")
                XCTFail("\(status) must throw")
            } catch {}
            XCTAssertEqual(rejected.tokens, reported, "\(status)")
            XCTAssertEqual(transport.requests.count, 1, "\(status): never retried")
        }
    }

    /// ⛔ ONLY THE TOKEN REFUSED IS CLEARED: one the app minted meanwhile survives.
    func testA401ClearsTheStoredTokenOnlyIfItIsStillTheOneRefused() {
        let stale = MemoryTokens(Self.live)
        stale.clear(ifStill: "notify-jws")
        XCTAssertNil(stale.stored)

        let renewed = MemoryTokens(NotifyToken(token: "fresh-jws", expiresAt: Self.live.expiresAt))
        renewed.clear(ifStill: "notify-jws")
        XCTAssertEqual(renewed.stored?.token, "fresh-jws")

        let unreadable = MemoryTokens(Self.live, readFails: true)
        unreadable.clear(ifStill: "notify-jws")
        XCTAssertEqual(unreadable.stored, Self.live, "a Keychain that cannot answer is left alone")
    }

    func testTheTitleTakesTheNameOrNothing() {
        XCTAssertEqual(
            MessageAlertNaming.title(template: "New message · {name}", name: "Avery"),
            "New message · Avery"
        )
        XCTAssertEqual(
            MessageAlertNaming.title(template: "Nouveau message · {name}", name: "Élodie"),
            "Nouveau message · Élodie"
        )
        // A table that did not load answers its key: the alert keeps its own title.
        XCTAssertNil(MessageAlertNaming.title(template: MessageAlertNaming.titleKey, name: "Avery"))
    }

    // MARK: - Fixtures

    private static let live = NotifyToken(token: "notify-jws", expiresAt: Date(timeIntervalSince1970: 1_900_000_000))

    private static func entitlements(_ path: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // App/Tests
            .deletingLastPathComponent() // App
            .deletingLastPathComponent() // the checkout
            .appendingPathComponent(path)
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }
}

private struct Failure {
    let label: String
    let tokens: FakeTokens
    let fetcher: FakeFetcher
}

private struct Ask: Equatable {
    let target: MessageAlertTarget
    let token: String
}

private struct FakeTokens: NotifyTokenReading {
    let result: Result<NotifyToken?, NotifyTokenKeychainError>

    init(_ result: Result<NotifyToken?, NotifyTokenKeychainError>) {
        self.result = result
    }

    func read() throws -> NotifyToken? {
        try result.get()
    }
}

private final class FakeFetcher: SenderNameFetching, @unchecked Sendable {
    private let lock = NSLock()
    private let answer: Result<String?, URLError>
    private let delay: Duration?
    private var log: [Ask] = []

    init(answer: Result<String?, URLError>, delay: Duration? = nil) {
        self.answer = answer
        self.delay = delay
    }

    var asked: [Ask] {
        lock.withLock { log }
    }

    func senderName(of target: MessageAlertTarget, token: String) async throws -> String? {
        lock.withLock { log.append(Ask(target: target, token: token)) }
        if let delay {
            try await Task.sleep(for: delay)
        }
        return try answer.get()
    }
}

/// Answers every request with one status and body, and records each.
private final class SenderTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let status: Int
    private let body: String
    private var log: [HTTPRequest] = []

    init(status: Int, body: String) {
        self.status = status
        self.body = body
    }

    var requests: [HTTPRequest] {
        lock.withLock { log }
    }

    func send(_ request: HTTPRequest, followRedirects _: Bool) async throws -> HTTPResponse {
        lock.withLock { log.append(request) }
        return HTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
    }
}

private final class RejectedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []

    var tokens: [String] {
        lock.withLock { log }
    }

    var record: @Sendable (String) -> Void {
        { [self] token in lock.withLock { log.append(token) } }
    }
}

/// A notify-token store in memory, standing in for the Keychain.
final class MemoryTokens: NotifyTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: NotifyToken?
    private let readFails: Bool
    let canStore: Bool
    private(set) var writes = 0
    private(set) var clears = 0

    init(_ token: NotifyToken?, readFails: Bool = false, canStore: Bool = true) {
        self.token = token
        self.readFails = readFails
        self.canStore = canStore
    }

    var stored: NotifyToken? {
        lock.withLock { token }
    }

    func read() throws -> NotifyToken? {
        if readFails {
            throw NotifyTokenKeychainError.status(errSecInteractionNotAllowed)
        }
        return stored
    }

    func write(_ token: NotifyToken) throws {
        lock.withLock {
            writes += 1
            self.token = token
        }
    }

    func clear() throws {
        lock.withLock {
            clears += 1
            token = nil
        }
    }
}
