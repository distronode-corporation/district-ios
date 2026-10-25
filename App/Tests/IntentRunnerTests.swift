@testable import DistrictAI
import DistrictData
import DistrictModel
import Foundation
import XCTest

/// "Set my availability" and "Read my latest message" (3.2): what Siri says, from what the
/// phone's own repositories answer, and the watch's request for the latest message.
@MainActor
final class IntentRunnerTests: XCTestCase {
    // MARK: - Set my availability

    func testTurningCallsOnSaysSoAndTellsTheWatch() async {
        let sources = FakeIntentSources()
        sources.saved = .success(Self.availability(#"{"success":true,"availableForCalls":true}"#))

        let sentence = await IntentRunner(sources: sources).setAvailability(true)

        XCTAssertEqual(sentence, "Calls in Plomberie Desrosiers now ring your phone.")
        XCTAssertEqual(sources.saves, ["ws_1=true"])
        XCTAssertEqual(sources.changes, 1)
    }

    /// ⛔ THE SERVER'S VALUE, NOT THE ONE ASKED FOR.
    func testTheAnswerIsTheServersValue() async {
        let sources = FakeIntentSources()
        sources.saved = .success(Self.availability(#"{"success":true,"availableForCalls":false}"#))

        let sentence = await IntentRunner(sources: sources).setAvailability(true)

        XCTAssertEqual(sentence, "Calls in Plomberie Desrosiers no longer ring your phone.")
    }

    /// ⛔ A VIEWER GETS A 200 WITH A REASON, AND THE REASON IS SAID.
    func testAReasonIsSaidInsteadOfASwitch() async {
        let sources = FakeIntentSources()
        sources.saved = .success(Self.availability(#"{"success":true,"availableForCalls":false,"reason":"role"}"#))

        let sentence = await IntentRunner(sources: sources).setAvailability(true)

        XCTAssertEqual(sentence, AvailabilityCopy.reasonRole)
    }

    func testARefusedSaveSaysTheServersSentence() async {
        let sources = FakeIntentSources()
        sources.saved = .failure(.http(status: 403, message: "Viewers cannot change this", code: nil))

        let sentence = await IntentRunner(sources: sources).setAvailability(false)

        XCTAssertEqual(sentence, "Viewers cannot change this")
        XCTAssertEqual(sources.changes, 0)
    }

    func testNoSessionOrNoWorkspaceWritesNothing() async {
        let sources = FakeIntentSources()
        sources.workspaceResult = .failure(WatchActionFailure(sentence: IntentCopy.noWorkspace))

        let availability = await IntentRunner(sources: sources).setAvailability(true)
        let latest = await IntentRunner(sources: sources).latestMessageSentence()

        XCTAssertEqual(availability, "Open District AI and choose a workspace first.")
        XCTAssertEqual(latest, IntentCopy.noWorkspace)
        XCTAssertEqual(sources.saves, [])
        XCTAssertEqual(sources.reads, [])
    }

    // MARK: - Read my latest message

    func testTheNewestConversationIsSaidWithoutItsGlyph() async {
        let sources = FakeIntentSources()
        sources.rows = .success([
            Self.conversation(name: "Older", body: "Old news", direction: "inbound", at: "2026-10-20T10:00:00.000Z"),
            Self.conversation(
                name: "Marie Tremblay",
                body: "Is 3 pm free?",
                direction: "inbound",
                at: "2026-10-25T09:00:00.000Z"
            ),
        ])

        let sentence = await IntentRunner(sources: sources).latestMessageSentence()

        XCTAssertEqual(sentence, "Latest message · Marie Tremblay: Is 3 pm free?")
        XCTAssertEqual(sources.reads, ["ws_1"])
    }

    func testAReplyIsSaidAsTheBusinesssOwn() async {
        let sources = FakeIntentSources()
        sources.rows = .success([
            Self.conversation(
                name: "Marie Tremblay",
                body: "See you then.",
                direction: "outbound",
                at: "2026-10-25T09:00:00.000Z"
            ),
        ])

        let sentence = await IntentRunner(sources: sources).latestMessageSentence()

        XCTAssertEqual(sentence, "Your latest reply · Marie Tremblay: See you then.")
    }

    func testAnEmptyInboxAndAFailedReadAreSaid() async {
        let sources = FakeIntentSources()
        sources.rows = .success([])
        let empty = await IntentRunner(sources: sources).latestMessageSentence()
        sources.rows = .failure(.http(status: 403, message: "The inbox is down", code: nil))
        let failed = await IntentRunner(sources: sources).latestMessageSentence()

        XCTAssertEqual(empty, "There are no messages in your inbox.")
        XCTAssertEqual(failed, "The inbox is down")
    }

    /// ⚠️ A TIME THAT CANNOT BE READ SORTS LAST; TIES KEEP THE LIST'S ORDER.
    func testTheNewestIsByTimeAndAnUnreadableTimeSortsLast() {
        let rows = [
            Self.conversation(name: "A", body: "a", direction: "inbound", at: "not a time"),
            Self.conversation(name: "B", body: "b", direction: "inbound", at: "2026-10-25T09:00:00.000Z"),
            Self.conversation(name: "C", body: "c", direction: "inbound", at: "2026-10-25T09:00:00.000Z"),
        ]
        XCTAssertEqual(IntentRunner.newest(rows)?.contactName, "B")
        XCTAssertEqual(IntentRunner.newest([rows[0]])?.contactName, "A")
        XCTAssertNil(IntentRunner.newest([]))
    }

    func testTheLineReadsTheGlyphOff() {
        func row(_ preview: String) -> WatchSnapshot.Conversation {
            .init(id: "contact:c", workspaceId: "ws_1", title: "Avery", preview: preview, unread: true, canReply: true)
        }
        XCTAssertEqual(LatestMessageLine(row("↑ Done")), LatestMessageLine(row("↑ Done")))
        XCTAssertEqual(LatestMessageLine(row("↑ Done")).outbound, true)
        XCTAssertEqual(LatestMessageLine(row("↑ Done")).text, "Done")
        XCTAssertEqual(LatestMessageLine(row("↓ Hello")).outbound, false)
        XCTAssertEqual(LatestMessageLine(row("↓ Hello")).text, "Hello")
        XCTAssertEqual(LatestMessageLine(row("Plain")).text, "Plain")
        XCTAssertEqual(LatestMessageLine(row("Plain")).name, "Avery")
    }

    // MARK: - The watch's request

    func testTheWatchsRequestIsAnsweredWithTheRowAndNoSnapshot() async throws {
        let sources = FakeIntentSources()
        sources.rows = .success([
            Self.conversation(
                name: "Marie Tremblay",
                body: "Is 3 pm free?",
                direction: "inbound",
                at: "2026-10-25T09:00:00.000Z"
            ),
        ])
        let link = SilentWatchLink()
        let snapshots = CountingSnapshotSource()
        let service = WatchBridgeService(
            link: link,
            source: snapshots,
            actions: RefusingWatchActions(),
            latest: IntentRunner(sources: sources),
            backgroundTasks: FakeBackgroundTasks()
        )
        let replies = LatestReplies()

        let data = try WatchWire.encoder.encode(WatchRequest(action: .latestMessage(workspaceId: "ws_9")))
        await service.handle(requestData: data, reply: replies.record)

        XCTAssertEqual(sources.reads, ["ws_9"], "the workspace the watch named")
        let reply = try XCTUnwrap(replies.all.first)
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.latestMessage?.title, "Marie Tremblay")
        XCTAssertEqual(reply.latestMessage?.preview, "↓ Is 3 pm free?")
        XCTAssertEqual(snapshots.builds, 0, "display-only: nothing to publish")
    }

    func testAPhoneWithoutAReaderAnswersAsAnOlderOne() async throws {
        let service = WatchBridgeService(
            link: SilentWatchLink(),
            source: CountingSnapshotSource(),
            actions: RefusingWatchActions(),
            backgroundTasks: FakeBackgroundTasks()
        )
        let replies = LatestReplies()

        let data = try WatchWire.encoder.encode(WatchRequest(action: .latestMessage(workspaceId: "ws_1")))
        await service.handle(requestData: data, reply: replies.record)

        XCTAssertEqual(replies.all, [.failure(WatchBridgeCopy.updateBothApps)])
    }

    func testTheLatestReplyRoundTripsAndAnEmptyInboxIsOkWithNoRow() throws {
        let row = WatchSnapshot.Conversation(
            id: "contact:c", workspaceId: "ws_1", title: "Avery", preview: "↓ Hi", unread: true, canReply: true
        )
        XCTAssertEqual(WatchReply.read(WatchReply.latest(row).message())?.latestMessage, row)
        let empty = try XCTUnwrap(WatchReply.read(WatchReply.latest(nil).message()))
        XCTAssertTrue(empty.ok)
        XCTAssertNil(empty.latestMessage)
    }

    // MARK: - Fixtures

    static func availability(_ json: String) -> AvailabilityResponse {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(AvailabilityResponse.self, from: Data(json.utf8))
    }

    /// ⚠️ DECODED FROM JSON: `ConversationSummary`'s initialiser is internal to the package.
    static func conversation(name: String, body: String, direction: String, at time: String) -> ConversationSummary {
        let json = #"""
        {"key":"k","threadKey":"contact:\#(name)","counterpart":"+15550101","matchKeys":["15550101"],
         "kind":"sms","channels":["sms"],"contactId":"c_1","contactName":"\#(name)",
         "contactEmail":null,"contactPhone":"+15550101","canSms":true,"canEmail":false,
         "lastMessage":{"body":"\#(body)","direction":"\#(direction)","type":null,"status":"received",
         "createdAt":"\#(time)"},"unreadCount":1,"totalMessages":1}
        """#
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(ConversationSummary.self, from: Data(json.utf8))
    }
}

// MARK: - Fakes

@MainActor
private final class FakeIntentSources: IntentSourcing {
    var workspaceResult: Result<IntentWorkspace, WatchActionFailure> = .success(
        IntentWorkspace(id: "ws_1", name: "Plomberie Desrosiers")
    )
    var saved: Result<AvailabilityResponse, ApiError> = .failure(.transport("unset"))
    var rows: Result<[ConversationSummary], ApiError> = .success([])
    private(set) var saves: [String] = []
    private(set) var reads: [String] = []
    private(set) var changes = 0

    func workspace() async -> Result<IntentWorkspace, WatchActionFailure> {
        workspaceResult
    }

    func saveAvailability(workspaceId: String, available: Bool) async -> Result<AvailabilityResponse, ApiError> {
        saves.append("\(workspaceId)=\(available)")
        return saved
    }

    func conversations(workspaceId: String) async -> Result<[ConversationSummary], ApiError> {
        reads.append(workspaceId)
        return rows
    }

    func availabilityChanged() {
        changes += 1
    }
}

@MainActor
private final class SilentWatchLink: WatchSessionLinking {
    let isCompanionInstalled = true

    func activate(
        onReady _: @escaping @MainActor @Sendable () -> Void,
        onRequest _: @escaping @MainActor @Sendable (Data, @escaping @Sendable ([String: Any]) -> Void) -> Void
    ) {}

    func publish(_: [String: Any]) throws {}
}

@MainActor
private final class CountingSnapshotSource: WatchSnapshotSourcing {
    private(set) var builds = 0

    func snapshot(at _: Date) async -> WatchSnapshot? {
        builds += 1
        return nil
    }
}

@MainActor
private struct RefusingWatchActions: WatchActionPerforming {
    func perform(_: WatchAction) async -> Result<Void, WatchActionFailure> {
        .failure(WatchActionFailure(sentence: "not here"))
    }

    func threadKey(workspaceId _: String, messageId _: String) async -> Result<String, WatchActionFailure> {
        .failure(WatchActionFailure(sentence: "not here"))
    }
}

private final class LatestReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [WatchReply] = []

    var all: [WatchReply] {
        lock.withLock { replies }
    }

    var record: @Sendable ([String: Any]) -> Void {
        { [self] message in
            guard let reply = WatchReply.read(message) else { return }
            lock.withLock { replies.append(reply) }
        }
    }
}
