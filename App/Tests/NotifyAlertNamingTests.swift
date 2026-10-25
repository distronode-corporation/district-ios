@testable import DistrictAI
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

    /// The pending fetcher, until district-core-swift 7.2.0: never a name.
    func testThePendingFetcherNamesNobody() async throws {
        let name = try await PendingSenderNameFetcher().senderName(of: target, token: "notify-jws")
        XCTAssertNil(name)
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
