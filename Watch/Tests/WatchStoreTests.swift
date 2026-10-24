@testable import DistrictAIWatch
import Foundation
import UserNotifications
import XCTest

/// The watch's one model, against a phone that is a fake.
///
/// ⚠️ THE STATES A SIMULATOR PAIR CANNOT REACH ON DEMAND: a phone out of range, a phone
/// that refuses, a snapshot gone stale, a phone on another version.
@MainActor
final class WatchStoreTests: XCTestCase {
    // MARK: - Writes

    func testAnUnreachablePhoneIsSaidSoAndNothingIsSent() async {
        let rig = Rig(reachable: false)
        rig.store.apply(.snapshot(Self.snapshot()))

        await rig.store.setAvailable(false)

        XCTAssertEqual(rig.store.writes[WriteKey.availability], .unreachable)
        XCTAssertTrue(rig.link.sent.isEmpty)
    }

    func testAPhoneRefusalShowsItsSentenceUnderTheFailureTitle() async throws {
        let rig = Rig(answer: .reply(.failure("You do not have permission to do that in this workspace.")))
        let conversation = try XCTUnwrap(Self.snapshot().conversations?[0])
        rig.store.apply(.snapshot(Self.snapshot()))

        await rig.store.reply("On my way.", to: conversation)

        XCTAssertEqual(
            rig.store.writes[WriteKey.reply(conversation.id)],
            .failed(
                title: WatchCopy.replyNotSent,
                reason: "You do not have permission to do that in this workspace."
            )
        )
        XCTAssertEqual(rig.link.sent, [
            .reply(workspaceId: "ws_1", threadKey: "contact:c_1", text: "On my way."),
        ])
    }

    /// ⛔ A MESSAGE THAT GOT NO ANSWER IS A FAILURE, NEVER A SUCCESS: the write may or may
    /// not have happened, and only "sent" would be a lie.
    func testNoAnswerIsAFailureNotASuccess() async throws {
        let rig = Rig(answer: .noAnswer)
        let conversation = try XCTUnwrap(Self.snapshot().conversations?[0])
        rig.store.apply(.snapshot(Self.snapshot()))

        await rig.store.markRead(conversation)

        XCTAssertEqual(
            rig.store.writes[WriteKey.markRead(conversation.id)],
            .failed(title: WatchCopy.markReadFailed, reason: WatchCopy.iphoneDidNotAnswer)
        )
    }

    func testUnreachableOnSendIsUnreachable() async {
        let rig = Rig(answer: .unreachable)
        rig.store.apply(.snapshot(Self.snapshot()))

        await rig.store.setAvailable(false)

        XCTAssertEqual(rig.store.writes[WriteKey.availability], .unreachable)
    }

    func testASuccessfulReplySaysSent() async throws {
        let rig = Rig(answer: .reply(.success))
        let conversation = try XCTUnwrap(Self.snapshot().conversations?[0])
        rig.store.apply(.snapshot(Self.snapshot()))

        await rig.store.reply("  Thanks, got it.  ", to: conversation)

        XCTAssertEqual(rig.store.writes[WriteKey.reply(conversation.id)], .succeeded(WatchCopy.replySent))
        XCTAssertEqual(rig.link.sent, [
            .reply(workspaceId: "ws_1", threadKey: "contact:c_1", text: "Thanks, got it."),
        ])
    }

    /// ⛔ THE SERVER'S REASON STANDS: a viewer's switch is not drawn, and no write is tried.
    func testAvailabilityThatCannotBeToggledSendsNothing() async {
        let rig = Rig(answer: .reply(.success))
        var snapshot = Self.snapshot()
        snapshot.availability?.canToggle = false
        rig.store.apply(.snapshot(snapshot))

        await rig.store.setAvailable(true)

        XCTAssertTrue(rig.link.sent.isEmpty)
        XCTAssertNil(rig.store.writes[WriteKey.availability])
    }

    func testAnEmptyReplySendsNothing() async throws {
        let rig = Rig(answer: .reply(.success))
        rig.store.apply(.snapshot(Self.snapshot()))

        try await rig.store.reply("   ", to: XCTUnwrap(Self.snapshot().conversations?[0]))

        XCTAssertTrue(rig.link.sent.isEmpty)
    }

    // MARK: - Snapshots

    func testAStaleSnapshotShowsWhenItWasUpdated() {
        let rig = Rig()
        let taken = Date(timeIntervalSince1970: 1_800_000_000)
        rig.store.apply(.snapshot(Self.snapshot(at: taken)))

        XCTAssertNil(rig.store.staleBanner(at: taken.addingTimeInterval(14 * 60)))
        let banner = rig.store.staleBanner(at: taken.addingTimeInterval(20 * 60))
        XCTAssertNotNil(banner)
        XCTAssertTrue(banner?.hasPrefix("Updated ") == true, banner ?? "nil")
    }

    func testTheBannerFollowsThePhonesFrench() {
        let rig = Rig()
        let taken = Date(timeIntervalSince1970: 1_800_000_000)
        var snapshot = Self.snapshot(at: taken)
        snapshot.language = "fr-CA"
        rig.store.apply(.snapshot(snapshot))
        defer { WatchL10n.phoneLanguage = nil }

        XCTAssertTrue(rig.store.staleBanner(at: taken.addingTimeInterval(20 * 60))?.hasPrefix("Mis à jour ") == true)
    }

    func testAVersionMismatchShowsUpdateAndClearsTheComplication() {
        let rig = Rig()
        rig.store.apply(.snapshot(Self.snapshot()))

        rig.store.apply(.versionMismatch(2))

        XCTAssertEqual(rig.store.phase, .versionMismatch)
        XCTAssertEqual(rig.complication.published.last, .unknown)
    }

    /// ⛔ A SIGNED-OUT SNAPSHOT LEAVES NOTHING OF THE LAST ACCOUNT, kept or shown.
    func testSignedOutClearsTheAccount() async {
        let rig = Rig(reachable: false)
        rig.store.apply(.snapshot(Self.snapshot()))
        await rig.store.setAvailable(false)

        rig.store.apply(.snapshot(.signedOut(at: Date(), language: "en")))

        XCTAssertEqual(rig.store.phase, .signedOut)
        XCTAssertTrue(rig.store.writes.isEmpty)
        XCTAssertEqual(rig.complication.published.last?.signedIn, false)
        XCTAssertNil(rig.complication.published.last?.workspaceName)
        guard let kept = rig.persistence.saved.last,
              case let .snapshot(stored) = WatchSnapshot.read(data: kept)
        else { return XCTFail("nothing kept") }
        XCTAssertFalse(stored.signedIn)
        XCTAssertNil(stored.conversations)
    }

    func testTheComplicationGetsAvailabilityAndTheWorkspaceName() {
        let rig = Rig()
        rig.store.apply(.snapshot(Self.snapshot()))

        XCTAssertEqual(
            rig.complication.published.last,
            ComplicationState(signedIn: true, workspaceName: "Plomberie Desrosiers", available: true, language: "en")
        )
    }

    /// ⛔ ONE LINE ON THE RECTANGULAR FACE: the full "Open District AI on your iPhone" cannot
    /// fit there, so the headline with nothing to show takes the short form.
    func testTheRectangularHeadlineIsShortWhenThereIsNothingToShow() {
        let unknown = ComplicationState(signedIn: true, workspaceName: nil, available: nil, language: "en")
        XCTAssertEqual(ComplicationView.headline(for: unknown), WatchCopy.openIphoneShort)
        XCTAssertNotEqual(WatchCopy.openIphoneShort, WatchCopy.openIphone)

        let signedOut = ComplicationState(signedIn: false, workspaceName: nil, available: nil, language: nil)
        XCTAssertEqual(ComplicationView.headline(for: signedOut), WatchCopy.signedOut)
        let name = "Plomberie Desrosiers"
        let available = ComplicationState(signedIn: true, workspaceName: name, available: true, language: "en")
        XCTAssertEqual(ComplicationView.headline(for: available), WatchCopy.available)
        let away = ComplicationState(signedIn: true, workspaceName: name, available: false, language: "en")
        XCTAssertEqual(ComplicationView.headline(for: away), WatchCopy.notAvailable)
    }

    func testAnUnreadableContextKeepsWhatIsShown() {
        let rig = Rig()
        rig.store.apply(.snapshot(Self.snapshot()))

        rig.store.apply(.unreadable)

        XCTAssertEqual(rig.store.snapshot, Self.snapshot())
    }

    func testAColdStartShowsTheKeptSnapshot() throws {
        let rig = Rig(reachable: false)
        rig.persistence.saved = try [Self.snapshot().encoded()]

        rig.store.start()

        XCTAssertEqual(rig.store.snapshot, Self.snapshot())
    }

    // MARK: - A tapped notification

    /// The thread the phone names, listed in the snapshot: Inbox, then that thread.
    func testAMessageTapOpensItsThreadOnceThePhoneNamesIt() async throws {
        let rig = Rig(answer: .reply(.thread("contact:c_1")))
        rig.store.apply(.snapshot(Self.snapshot()))

        await rig.store.open(Self.tap())

        let conversation = try XCTUnwrap(Self.snapshot().conversations?[0])
        XCTAssertEqual(rig.store.path, [.inbox, .thread(conversation)])
        XCTAssertEqual(rig.link.sent, [.resolveMessage(workspaceId: "ws_1", messageId: "msg_1")])
    }

    /// ⛔ ANOTHER WORKSPACE OPENS HOME, and the phone is not asked.
    func testAMessageFromAnotherWorkspaceOpensHome() async {
        let rig = Rig(answer: .reply(.thread("contact:c_1")))
        rig.store.apply(.snapshot(Self.snapshot()))
        rig.store.path = [.calls]

        await rig.store.open(Self.tap(workspaceId: "ws_2"))

        XCTAssertEqual(rig.store.path, [])
        XCTAssertTrue(rig.link.sent.isEmpty)
    }

    /// ⚠️ A THREAD THE SNAPSHOT DOES NOT LIST YET: the inbox, never a blank screen, and the
    /// thread opens when the next snapshot carries it.
    func testAThreadNotListedYetStaysOnTheInboxUntilASnapshotCarriesIt() async {
        let rig = Rig(answer: .reply(.thread("contact:c_new")))
        rig.store.apply(.snapshot(Self.snapshot()))

        await rig.store.open(Self.tap())
        XCTAssertEqual(rig.store.path, [.inbox])

        var fresh = Self.snapshot()
        let arrived = WatchSnapshot.Conversation(
            id: "contact:c_new", workspaceId: "ws_1", title: "Luc Gagnon",
            preview: "↓ Bonjour", unread: true, canReply: true
        )
        fresh.conversations?.insert(arrived, at: 0)
        rig.store.apply(.snapshot(fresh))

        XCTAssertEqual(rig.store.path, [.inbox, .thread(arrived)])
        XCTAssertEqual(rig.link.sent.count, 1)
    }

    /// ⚠️ A WINDOW, NOT A STANDING ORDER: a thread that turns up after it closes moves nothing.
    func testAThreadListedAfterTheWindowMovesNothing() async {
        let clock = TestClock()
        let rig = Rig(answer: .reply(.thread("contact:c_new")), clock: clock)
        rig.store.apply(.snapshot(Self.snapshot()))
        await rig.store.open(Self.tap())

        clock.now += WatchStore.routeWindow + 1
        var fresh = Self.snapshot()
        fresh.conversations?.append(.init(
            id: "contact:c_new", workspaceId: "ws_1", title: "Luc Gagnon",
            preview: "↓ Bonjour", unread: true, canReply: true
        ))
        rig.store.apply(.snapshot(fresh))

        XCTAssertEqual(rig.store.path, [.inbox])
    }

    /// ⚠️ A PERSON WHO HAS MOVED ON IS NOT PULLED BACK.
    func testLeavingTheInboxCancelsTheRoute() async {
        let rig = Rig(answer: .reply(.thread("contact:c_new")))
        rig.store.apply(.snapshot(Self.snapshot()))
        await rig.store.open(Self.tap())

        rig.store.path = [.calls]
        var fresh = Self.snapshot()
        fresh.conversations?.append(.init(
            id: "contact:c_new", workspaceId: "ws_1", title: "Luc Gagnon",
            preview: "↓ Bonjour", unread: true, canReply: true
        ))
        rig.store.apply(.snapshot(fresh))

        XCTAssertEqual(rig.store.path, [.calls])
    }

    /// ⚠️ A PHONE OUT OF REACH (a cold launch, before the session is up) is asked again when
    /// its next snapshot arrives.
    func testAnUnreachablePhoneIsAskedAgainOnItsNextSnapshot() async throws {
        let rig = Rig(reachable: false, answer: .reply(.thread("contact:c_1")))
        rig.store.apply(.snapshot(Self.snapshot()))

        await rig.store.open(Self.tap())
        XCTAssertEqual(rig.store.path, [.inbox])
        XCTAssertTrue(rig.link.sent.isEmpty)

        rig.link.isReachable = true
        rig.store.apply(.snapshot(Self.snapshot()))
        await rig.store.settleRoute()

        let conversation = try XCTUnwrap(Self.snapshot().conversations?[0])
        XCTAssertEqual(rig.store.path, [.inbox, .thread(conversation)])
        XCTAssertEqual(rig.link.sent.count, 1)
    }

    /// ⚠️ A TAP THAT RESUMES THE APP lands before the phone is back in reach, and no snapshot
    /// need follow: coming into reach is what asks (seen on the simulator pair).
    func testThePhoneComingIntoReachAsksForTheThread() async throws {
        let rig = Rig(reachable: false, answer: .reply(.thread("contact:c_1")))
        rig.store.start()
        rig.store.apply(.snapshot(Self.snapshot()))
        await rig.store.open(Self.tap())
        XCTAssertTrue(rig.link.sent.isEmpty)

        rig.link.isReachable = true
        rig.link.onReachable?()
        await rig.store.settleRoute()

        let conversation = try XCTUnwrap(Self.snapshot().conversations?[0])
        XCTAssertEqual(rig.store.path, [.inbox, .thread(conversation)])
        XCTAssertEqual(rig.link.sent, [.resolveMessage(workspaceId: "ws_1", messageId: "msg_1")])
    }

    /// ⚠️ AN OLDER PHONE ("update both apps") OR A REFUSAL: the inbox stays, and nothing is
    /// asked again.
    func testAPhoneThatCannotResolveLeavesTheInbox() async {
        let rig = Rig(answer: .reply(.failure("Update District AI on both devices.")))
        rig.store.apply(.snapshot(Self.snapshot()))

        await rig.store.open(Self.tap())
        rig.store.apply(.snapshot(Self.snapshot()))
        await rig.store.settleRoute()

        XCTAssertEqual(rig.store.path, [.inbox])
        XCTAssertEqual(rig.link.sent.count, 1)
    }

    /// ⛔ NOT A MESSAGE, OR NOT A WHOLE ONE: nothing moves and nothing is sent.
    func testAPayloadThatIsNotAMessageMovesNothing() async {
        let rig = Rig(answer: .reply(.thread("contact:c_1")))
        rig.store.apply(.snapshot(Self.snapshot()))
        rig.store.path = [.calls]

        await rig.store.open(["type": "incoming_call", "workspaceId": "ws_1", "callId": "call_1"])
        await rig.store.open(["type": "message", "workspaceId": "ws_1"])

        XCTAssertEqual(rig.store.path, [.calls])
        XCTAssertTrue(rig.link.sent.isEmpty)
    }

    /// ⛔ SIGNED OUT, NOTHING OPENS, AND A SIGN-OUT CLEARS AN OPEN THREAD.
    func testSignedOutOpensNothingAndASignOutClearsThePath() async {
        let rig = Rig(answer: .reply(.thread("contact:c_1")))
        rig.store.apply(.snapshot(Self.snapshot()))
        await rig.store.open(Self.tap())

        rig.store.apply(.snapshot(.signedOut(at: Date(), language: "en")))
        XCTAssertEqual(rig.store.path, [])

        await rig.store.open(Self.tap())
        XCTAssertEqual(rig.store.path, [])
        XCTAssertEqual(rig.link.sent.count, 1)
    }

    /// ⛔ THE PR #79 TRAP ON THIS PATH: the app's delegate, called off the main queue as the
    /// system calls it, reaches the store rather than trapping. A regression is a crashed
    /// test process, not a red assertion.
    func testTheAppsDelegateCalledOffTheMainQueueOpensTheThread() async throws {
        let rig = Rig(answer: .reply(.thread("contact:c_1")))
        rig.store.apply(.snapshot(Self.snapshot()))
        let delegate = WatchNotificationDelegate.routing(to: rig.store)
        let userInfo: [String: String] = Self.tap()

        DispatchQueue.global().async {
            delegate.receive(actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: userInfo)
        }
        for _ in 0 ..< 200 where rig.store.path.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }

        let conversation = try XCTUnwrap(Self.snapshot().conversations?[0])
        XCTAssertEqual(rig.store.path, [.inbox, .thread(conversation)])
    }

    static func tap(workspaceId: String = "ws_1") -> [String: String] {
        ["type": "message", "category": "district.message", "workspaceId": workspaceId, "messageId": "msg_1"]
    }

    // MARK: - Fixtures

    static func snapshot(at date: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> WatchSnapshot {
        WatchSnapshot(
            protocolVersion: WatchSnapshot.currentProtocolVersion,
            generatedAt: date,
            language: "en",
            signedIn: true,
            workspace: .init(id: "ws_1", name: "Plomberie Desrosiers"),
            availability: .init(workspaceId: "ws_1", available: true, canToggle: true, note: nil),
            unreadCount: 2,
            calls: [],
            conversations: [
                .init(
                    id: "contact:c_1",
                    workspaceId: "ws_1",
                    title: "Marie Tremblay",
                    preview: "↓ Can you come by tomorrow?",
                    unread: true,
                    canReply: true
                ),
            ]
        )
    }
}

// MARK: - Fakes

@MainActor
private final class FakePhoneLink: PhoneLinking {
    var isReachable: Bool
    let answer: PhoneAnswer
    private(set) var sent: [WatchAction] = []

    init(reachable: Bool, answer: PhoneAnswer) {
        isReachable = reachable
        self.answer = answer
    }

    private(set) var onReachable: (@MainActor @Sendable () -> Void)?

    func activate(
        onReading _: @escaping @MainActor @Sendable (WatchSnapshotReading) -> Void,
        onReachable: @escaping @MainActor @Sendable () -> Void
    ) {
        self.onReachable = onReachable
    }

    func send(_ request: WatchRequest) async -> PhoneAnswer {
        sent.append(request.action)
        return answer
    }
}

@MainActor
private final class FakePersistence: SnapshotPersisting {
    var saved: [Data] = []

    func load() -> Data? {
        saved.last
    }

    func save(_ data: Data) {
        saved.append(data)
    }
}

@MainActor
private final class FakeComplication: ComplicationPublishing {
    private(set) var published: [ComplicationState] = []

    func publish(_ state: ComplicationState) {
        published.append(state)
    }
}

@MainActor
private final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
private struct Rig {
    let link: FakePhoneLink
    let persistence = FakePersistence()
    let complication = FakeComplication()
    let store: WatchStore

    init(reachable: Bool = true, answer: PhoneAnswer = .reply(.success), clock: TestClock = TestClock()) {
        link = FakePhoneLink(reachable: reachable, answer: answer)
        store = WatchStore(
            link: link,
            persistence: persistence,
            complication: complication,
            clock: { clock.now }
        )
    }
}
