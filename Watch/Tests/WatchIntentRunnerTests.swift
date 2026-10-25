@testable import DistrictAIWatch
import Foundation
import XCTest

/// "Set my availability" and "Read my latest message" on the watch (3.2): the switch's own
/// write, the phone asked for the inbox, and a sentence for every outcome.
@MainActor
final class WatchIntentRunnerTests: XCTestCase {
    override func tearDown() {
        WatchL10n.phoneLanguage = nil
        super.tearDown()
    }

    // MARK: - Set my availability

    func testAvailabilityIsTheSwitchsWriteAndSaysSo() async {
        let rig = IntentRig(answer: .reply(.success))

        let off = await rig.runner.setAvailability(false)

        XCTAssertEqual(rig.link.sent, [.setAvailability(workspaceId: "ws_1", available: false)])
        XCTAssertEqual(off, "Calls in Plomberie Desrosiers no longer ring your phone.")
        let on = await rig.runner.setAvailability(true)
        XCTAssertEqual(on, "Calls in Plomberie Desrosiers now ring your phone.")
    }

    func testARefusalIsThePhonesSentence() async {
        let rig = IntentRig(answer: .reply(.failure("You are a viewer.")))

        let sentence = await rig.runner.setAvailability(true)

        XCTAssertEqual(sentence, "You are a viewer.")
    }

    func testAnUnreachablePhoneIsSaidAfterTheWait() async {
        let rig = IntentRig(reachable: false, answer: .reply(.success))

        let sentence = await rig.runner.setAvailability(true)

        XCTAssertEqual(sentence, WatchCopy.iphoneNotReachable)
        XCTAssertEqual(rig.link.sent, [])
    }

    /// ⛔ A REASON IS SAID AND NOTHING IS SENT.
    func testAReasonIsSaidAndNothingIsSent() async {
        var snapshot = WatchStoreTests.snapshot()
        snapshot.availability = .init(workspaceId: "ws_1", available: false, canToggle: false, note: "A viewer.")
        let rig = IntentRig(answer: .reply(.success), snapshot: snapshot)

        let sentence = await rig.runner.setAvailability(true)

        XCTAssertEqual(sentence, "A viewer.")
        XCTAssertEqual(rig.link.sent, [])
    }

    func testNothingToActOnIsSaid() async {
        let empty = IntentRig(answer: .reply(.success), snapshot: nil)
        let waiting = await empty.runner.setAvailability(true)
        let waitingLatest = await empty.runner.latestMessage()
        XCTAssertEqual(waiting, WatchCopy.openIphone)
        XCTAssertEqual(waitingLatest, WatchCopy.openIphone)

        var noWorkspace = WatchStoreTests.snapshot()
        noWorkspace.workspace = nil
        let unscoped = IntentRig(answer: .reply(.success), snapshot: noWorkspace)
        let unscopedAvailability = await unscoped.runner.setAvailability(true)
        let unscopedLatest = await unscoped.runner.latestMessage()
        XCTAssertEqual(unscopedAvailability, WatchCopy.noWorkspace)
        XCTAssertEqual(unscopedLatest, WatchCopy.noWorkspace)

        var unknown = WatchStoreTests.snapshot()
        unknown.availability = nil
        let unread = await IntentRig(answer: .reply(.success), snapshot: unknown).runner.setAvailability(true)
        XCTAssertEqual(unread, WatchCopy.availabilityUnreadable)
        XCTAssertEqual(empty.link.sent + unscoped.link.sent, [])
    }

    // MARK: - Read my latest message

    func testTheLatestMessageIsAskedOfThePhoneAndSaid() async {
        let rig = IntentRig(answer: .reply(.latest(WatchStoreTests.snapshot().conversations?.first)))

        let sentence = await rig.runner.latestMessage()

        XCTAssertEqual(rig.link.sent, [.latestMessage(workspaceId: "ws_1")])
        XCTAssertEqual(sentence, "Latest message · Marie Tremblay: Can you come by tomorrow?")
    }

    func testAReplyAnEmptyInboxAndEachFailureAreSaid() async {
        let row = WatchSnapshot.Conversation(
            id: "contact:c_1", workspaceId: "ws_1", title: "Marie Tremblay", preview: "↑ See you then.",
            unread: false, canReply: true
        )
        let sent = await IntentRig(answer: .reply(.latest(row))).runner.latestMessage()
        let empty = await IntentRig(answer: .reply(.latest(nil))).runner.latestMessage()
        let old = await IntentRig(answer: .reply(.failure("Update District AI."))).runner.latestMessage()
        let silent = await IntentRig(answer: .noAnswer).runner.latestMessage()
        let gone = await IntentRig(answer: .unreachable).runner.latestMessage()
        let away = await IntentRig(reachable: false, answer: .reply(.success)).runner.latestMessage()

        XCTAssertEqual(sent, "Your latest reply · Marie Tremblay: See you then.")
        XCTAssertEqual(empty, "There are no messages in your inbox.")
        XCTAssertEqual(old, "Update District AI.")
        XCTAssertEqual(silent, WatchCopy.iphoneDidNotAnswer)
        XCTAssertEqual(gone, WatchCopy.iphoneNotReachable)
        XCTAssertEqual(away, WatchCopy.iphoneNotReachable)
    }

    func testTheSentencesFollowThePhonesFrench() async {
        var snapshot = WatchStoreTests.snapshot()
        snapshot.language = "fr-CA"
        let rig = IntentRig(answer: .reply(.latest(snapshot.conversations?.first)), snapshot: snapshot)

        let sentence = await rig.runner.latestMessage()

        XCTAssertEqual(sentence, "Dernier message · Marie Tremblay\u{00A0}: Can you come by tomorrow?")
    }
}

// MARK: - Fakes

@MainActor
private final class IntentPhoneLink: PhoneLinking {
    let isReachable: Bool
    let answer: PhoneAnswer
    private(set) var sent: [WatchAction] = []

    init(reachable: Bool, answer: PhoneAnswer) {
        isReachable = reachable
        self.answer = answer
    }

    func activate(
        onReading _: @escaping @MainActor @Sendable (WatchSnapshotReading) -> Void,
        onReachable _: @escaping @MainActor @Sendable () -> Void
    ) {}

    func send(_ request: WatchRequest) async -> PhoneAnswer {
        sent.append(request.action)
        return answer
    }
}

@MainActor
private struct NoPersistence: SnapshotPersisting {
    func load() -> Data? {
        nil
    }

    func save(_: Data) {}
}

@MainActor
private struct NoComplication: ComplicationPublishing {
    func publish(_: ComplicationState) {}
}

@MainActor
private struct IntentRig {
    let link: IntentPhoneLink
    let store: WatchStore
    let runner: WatchIntentRunner

    init(reachable: Bool = true, answer: PhoneAnswer, snapshot: WatchSnapshot? = WatchStoreTests.snapshot()) {
        link = IntentPhoneLink(reachable: reachable, answer: answer)
        store = WatchStore(link: link, persistence: NoPersistence(), complication: NoComplication())
        if let snapshot {
            store.apply(.snapshot(snapshot))
        }
        runner = WatchIntentRunner(store: store, link: link, reachabilityWait: .milliseconds(150))
    }
}
