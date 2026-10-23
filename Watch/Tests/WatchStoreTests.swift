@testable import DistrictAIWatch
import Foundation
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

    func activate(onReading _: @escaping @MainActor @Sendable (WatchSnapshotReading) -> Void) {}

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
private struct Rig {
    let link: FakePhoneLink
    let persistence = FakePersistence()
    let complication = FakeComplication()
    let store: WatchStore

    init(reachable: Bool = true, answer: PhoneAnswer = .reply(.success)) {
        link = FakePhoneLink(reachable: reachable, answer: answer)
        store = WatchStore(link: link, persistence: persistence, complication: complication)
    }
}
