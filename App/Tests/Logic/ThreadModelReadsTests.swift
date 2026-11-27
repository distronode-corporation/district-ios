@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The thread's reads and the AI draft, over a real ``InboxRepository`` and ``ApiClient``
/// answering a script of recorded-shape bodies.
///
/// ⛔ WHAT IS PINNED HERE: a malformed thread key never reaches the network, an older page is
/// merged by event id and re-sorted (the held copy wins a collision), a failed older page keeps
/// the conversation on screen, and an empty AI generation never blanks the composer.
@MainActor
final class ThreadModelReadsTests: XCTestCase {
    // MARK: - load()

    /// ⛔ A KEY IN NEITHER DOCUMENTED FORM IS NOT A RETRY: nothing is sent, and the failure
    /// offers no action.
    func testAMalformedThreadKeyFailsWithoutARequest() async {
        for key in ["contact:", "addr:", "c_1", "", "CONTACT:c_1"] {
            let transport = ThreadReadsTransport([])
            let model = Self.model(transport, threadKey: key)

            await model.load()

            guard case let .failed(failure) = model.state else {
                XCTFail("\(key): got \(model.state)")
                continue
            }
            XCTAssertEqual(failure.message, InboxCopy.conversationCouldNotOpened, key)
            XCTAssertEqual(failure.action, FailureText.Action.none, key)
            XCTAssertEqual(transport.urls.count, 0, key)
        }
    }

    func testAnAddressKeyReadsTheThreadByPhoneNumber() async throws {
        let transport = ThreadReadsTransport([Self.newest])
        let model = Self.model(transport, threadKey: "addr:+14165551234")

        await model.load()

        let url = try XCTUnwrap(transport.urls.first)
        XCTAssertEqual(Self.query(url, "phoneNumber"), "+14165551234")
        XCTAssertNil(Self.query(url, "contactId"))
        XCTAssertEqual(model.current?.events.map(\.id), ["msg_3", "msg_4"])
    }

    func testARefusedReadIsAFailureAndAnEmptyThreadIsNot() async {
        let refused = ThreadReadsTransport([Self.refused])
        let failing = Self.model(refused)
        await failing.load()
        guard case .failed = failing.state else { return XCTFail("got \(failing.state)") }
        XCTAssertNil(failing.current)

        let empty = ThreadReadsTransport([(200, #"{"success":true,"timeline":[]}"#)])
        let quiet = Self.model(empty)
        await quiet.load()
        guard case let .empty(content) = quiet.state else { return XCTFail("got \(quiet.state)") }
        XCTAssertFalse(content.hasMore, "no pageInfo is the end of the thread")
        XCTAssertNil(content.cursor)
    }

    /// ⛔ A BODY WITH NO `timeline` KEY IS MALFORMED, NOT AN EMPTY CONVERSATION.
    func testAMissingTimelineIsAFailureNotAnEmptyThread() async {
        let transport = ThreadReadsTransport([(200, #"{"success":true}"#)])
        let model = Self.model(transport)

        await model.load()

        guard case .failed = model.state else { return XCTFail("got \(model.state)") }
    }

    // MARK: - loadOlder()

    /// ⛔ MERGED BY ID, THE HELD COPY WINS, AND THE RESULT IS RE-SORTED; the new page's
    /// `hasMore` and cursor are adopted, and its dropped rows are counted.
    func testAnOlderPageIsMergedByIdAndResorted() async throws {
        let transport = ThreadReadsTransport([Self.newest, Self.older])
        let model = Self.model(transport)
        await model.load()
        XCTAssertEqual(model.current?.incompleteCount, 1, "the row with no id is counted, not shown")

        await model.loadOlder()

        let content = try XCTUnwrap(model.current)
        XCTAssertEqual(content.events.map(\.id), ["msg_1", "msg_2", "msg_3", "msg_4"])
        XCTAssertEqual(content.events.first { $0.id == "msg_3" }?.body, "Held copy")
        XCTAssertFalse(content.hasMore)
        XCTAssertNil(content.cursor)
        XCTAssertEqual(content.incompleteCount, 2)
        XCTAssertFalse(content.loadingOlder)
        XCTAssertNil(content.olderFailure)
        let olderURL = try XCTUnwrap(transport.urls.last)
        XCTAssertEqual(Self.query(olderURL, "before"), "2026-08-15T14:03:00.000Z")
        XCTAssertEqual(Self.query(olderURL, "beforeId"), "msg_3")
    }

    /// ⚠️ THE END OF THE THREAD ASKS FOR NOTHING MORE.
    func testNoOlderPageIsAskedForOnceTheThreadHasEnded() async {
        let transport = ThreadReadsTransport([Self.newest, Self.older])
        let model = Self.model(transport)
        await model.load()
        await model.loadOlder()

        await model.loadOlder()

        XCTAssertEqual(transport.urls.count, 2)
    }

    /// ⛔ A THREAD WITH NO `pageInfo` OFFERS NO OLDER PAGE AT ALL.
    func testAThreadWithoutPageInfoNeverPages() async {
        let transport = ThreadReadsTransport([Self.unpaged])
        let model = Self.model(transport)
        await model.load()

        await model.loadOlder()

        XCTAssertEqual(transport.urls.count, 1)
        XCTAssertEqual(model.current?.events.map(\.id), ["msg_9"])
    }

    /// ⛔ THE THREAD STAYS ON SCREEN WHEN THE OLDER PAGE FAILS, and the control remains.
    func testAFailedOlderPageKeepsTheConversation() async {
        let transport = ThreadReadsTransport([Self.newest, Self.refused])
        let model = Self.model(transport)
        await model.load()

        await model.loadOlder()

        guard case let .content(content) = model.state else { return XCTFail("got \(model.state)") }
        XCTAssertEqual(content.events.map(\.id), ["msg_3", "msg_4"])
        XCTAssertNotNil(content.olderFailure)
        XCTAssertTrue(content.hasMore, "the control is still offered")
        XCTAssertNotNil(content.cursor)
        XCTAssertFalse(content.loadingOlder)
    }

    func testLoadOlderBeforeAnyLoadDoesNothing() async {
        let transport = ThreadReadsTransport([Self.older])
        let model = Self.model(transport)

        await model.loadOlder()

        XCTAssertEqual(transport.urls.count, 0)
        guard case .loading = model.state else { return XCTFail("got \(model.state)") }
    }

    // MARK: - merge(held:older:)

    /// ⚠️ EQUAL TIMESTAMPS BREAK BY ID, the server's own total order.
    func testMergeBreaksATimestampTieById() async throws {
        let transport = ThreadReadsTransport([Self.tied, Self.tiedOlder])
        let repository = Self.repository(transport)
        let held = try await repository.timeline(workspaceId: "ws_1", selector: .contact("c_1")).get().events
        let older = try await repository.timeline(workspaceId: "ws_1", selector: .contact("c_1")).get().events

        let merged = ThreadModel.merge(held: held, older: older)

        XCTAssertEqual(merged.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(ThreadModel.merge(held: [], older: []).count, 0)
        XCTAssertEqual(ThreadModel.merge(held: held, older: held).map(\.id), ["b", "c"])
    }

    func testBlankIsWhitespaceAndNewlinesOnly() {
        XCTAssertTrue(ThreadModel.isBlank(""))
        XCTAssertTrue(ThreadModel.isBlank(" \n\t\r\n "))
        XCTAssertFalse(ThreadModel.isBlank(" . "))
        XCTAssertFalse(ThreadModel.isBlank("\u{00E9}"))
    }

    // MARK: - generateDraft()

    func testAGeneratedDraftFillsTheComposer() async {
        let transport = ThreadReadsTransport([Self.newest, (200, #"{"success":true,"draft":"See you Thursday."}"#)])
        let model = Self.model(transport)
        await model.load()

        await model.generateDraft()
        model.autosaveTask?.cancel()

        XCTAssertEqual(model.composerText, "See you Thursday.")
        XCTAssertEqual(model.current?.draftGenerating, false)
        XCTAssertNil(model.current?.sendFailure)
    }

    /// ⛔ AN EMPTY GENERATION NEVER BLANKS WHAT THE OPERATOR TYPED.
    func testABlankGenerationLeavesTheComposerAlone() async {
        let transport = ThreadReadsTransport([Self.newest, (200, #"{"success":true,"draft":"  \n "}"#)])
        let model = Self.model(transport)
        await model.load()
        model.adoptDraft("Typed by hand")

        await model.generateDraft()

        XCTAssertEqual(model.composerText, "Typed by hand")
        XCTAssertNil(model.autosaveTask, "nothing new to save")
        XCTAssertEqual(model.current?.draftGenerating, false)
    }

    /// A refused generation is said, the composer is untouched, and dismissing it clears it
    /// without disturbing the thread.
    func testAFailedGenerationIsSaidAndDismissable() async {
        let transport = ThreadReadsTransport([Self.newest, Self.refused])
        let model = Self.model(transport)
        await model.load()
        model.adoptDraft("Typed by hand")

        await model.generateDraft()
        XCTAssertNotNil(model.current?.sendFailure)
        XCTAssertEqual(model.current?.draftGenerating, false)
        XCTAssertEqual(model.composerText, "Typed by hand")

        model.dismissFailure()
        XCTAssertNil(model.current?.sendFailure)
        XCTAssertEqual(model.current?.events.map(\.id), ["msg_3", "msg_4"])
    }

    func testNoGenerationBeforeTheThreadHasLoaded() async {
        let transport = ThreadReadsTransport([Self.newest])
        let model = Self.model(transport)

        await model.generateDraft()
        model.dismissFailure()

        XCTAssertEqual(transport.urls.count, 0)
        XCTAssertEqual(model.composerText, "")
    }

    // MARK: - Who may write

    /// ⛔ A VIEWER, AND A ROLE THAT DID NOT PARSE, ARE READ-ONLY: no generation and no send.
    func testAReadOnlyRoleNeitherGeneratesNorSends() async {
        for role in [WorkspaceRole.viewer, nil] {
            let transport = ThreadReadsTransport([Self.newest])
            let model = Self.model(transport, role: role)
            await model.load()
            model.adoptDraft("Hello")

            await model.generateDraft()
            await model.send()

            XCTAssertFalse(model.canMutate)
            XCTAssertFalse(model.canReply)
            XCTAssertFalse(model.canAttach)
            XCTAssertEqual(transport.urls.count, 1, "only the read, for \(String(describing: role))")
            XCTAssertEqual(model.composerText, "Hello")
        }
    }

    /// ⛔ ATTACH IS SMS ONLY, AND NO TARGET AT ALL MEANS NO REPLY BOX.
    func testAttachFollowsTheSelectedChannel() {
        let transport = ThreadReadsTransport([])
        let email = Self.model(transport, targets: [ReplyTarget(to: "a@example.com", channel: MessageChannel.email)])
        XCTAssertTrue(email.canReply)
        XCTAssertFalse(email.canAttach)

        let none = Self.model(transport, targets: [])
        XCTAssertFalse(none.canReply)
        XCTAssertFalse(none.canAttach)

        let sms = Self.model(transport)
        XCTAssertTrue(sms.canAttach)
    }

    /// ⛔ AN EMPTY BODY IS NEVER SENT: the route 400s it before it looks at anything else.
    func testABlankBodyIsNotSent() async {
        let transport = ThreadReadsTransport([Self.newest])
        let model = Self.model(transport)
        await model.load()
        model.adoptDraft(" \n ")

        await model.send()

        XCTAssertEqual(transport.urls.count, 1)
        XCTAssertEqual(model.current?.sending, false)
    }

    // MARK: - Helpers

    private static func repository(_ transport: ThreadReadsTransport) -> InboxRepository {
        InboxRepository(client: ApiClient(
            baseURL: ApiClient.productionBaseURL,
            transport: transport,
            accessToken: { "session-token" }
        ))
    }

    private static func model(
        _ transport: ThreadReadsTransport,
        threadKey: String = "contact:c_1",
        role: WorkspaceRole? = .client,
        targets: [ReplyTarget] = [ReplyTarget(to: "+14165551234", channel: MessageChannel.sms)]
    ) -> ThreadModel {
        ThreadModel(
            inbox: repository(transport),
            workspaceId: "ws_1",
            role: role,
            threadKey: threadKey,
            replyTargets: targets
        )
    }

    private static func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    /// The newest window: two rows, one row with no id (dropped and counted), and a cursor.
    private static let newest = (200, #"""
    {"success":true,"timeline":[
     {"id":"msg_3","type":"sms","timestamp":"2026-08-15T14:03:00.000Z","direction":"inbound",
      "body":"Held copy","status":"received"},
     {"type":"sms","timestamp":"2026-08-15T14:03:30.000Z","direction":"inbound","body":"no id"},
     {"id":"msg_4","type":"sms","timestamp":"2026-08-15T14:04:00.000Z","direction":"outbound",
      "body":"Reply","status":"delivered"}],
     "pageInfo":{"hasMore":true,"oldest":"2026-08-15T14:03:00.000Z","oldestId":"msg_3"}}
    """#)

    /// The page behind it, out of order, overlapping on `msg_3`, with one dropped row and the end.
    private static let older = (200, #"""
    {"success":true,"timeline":[
     {"id":"msg_2","type":"sms","timestamp":"2026-08-15T14:02:00.000Z","direction":"inbound","body":"Two"},
     {"id":"msg_3","type":"sms","timestamp":"2026-08-15T14:03:00.000Z","direction":"inbound","body":"Server copy"},
     {"id":"","type":"sms","timestamp":"2026-08-15T14:01:30.000Z","direction":"inbound","body":"empty id"},
     {"id":"msg_1","type":"sms","timestamp":"2026-08-15T14:01:00.000Z","direction":"inbound","body":"One"}],
     "pageInfo":{"hasMore":false}}
    """#)

    /// The deployed route's shape: no `pageInfo` at all.
    private static let unpaged = (200, #"""
    {"success":true,"timeline":[
     {"id":"msg_9","type":"email","timestamp":"2026-08-15T14:09:00.000Z","direction":"inbound","body":"Hi"}]}
    """#)

    private static let tied = (200, #"""
    {"success":true,"timeline":[
     {"id":"c","timestamp":"2026-08-15T14:00:00.000Z"},
     {"id":"b","timestamp":"2026-08-15T13:00:00.000Z"}]}
    """#)

    private static let tiedOlder = (200, #"""
    {"success":true,"timeline":[
     {"id":"b","timestamp":"2026-08-15T13:00:00.000Z","body":"duplicate"},
     {"id":"a","timestamp":"2026-08-15T13:00:00.000Z"}]}
    """#)

    /// ⚠️ A 400, NOT A 5xx, so no transport-level retry blurs the count.
    private static let refused = (400, #"{"error":"refused"}"#)
}

/// Answers a fixed script of `(status, body)` in order and records every URL asked for; a
/// script that has run dry answers 500 rather than hanging.
private final class ThreadReadsTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [(Int, String)]
    private var asked: [URL] = []

    init(_ script: [(Int, String)]) {
        self.script = script
    }

    var urls: [URL] {
        lock.withLock { asked }
    }

    func send(_ request: HTTPRequest, followRedirects: Bool) async throws -> HTTPResponse {
        _ = followRedirects
        let next: (Int, String)? = lock.withLock {
            asked.append(request.url)
            return script.isEmpty ? nil : script.removeFirst()
        }
        guard let (status, body) = next else {
            return HTTPResponse(statusCode: 500, headers: [:], body: nil)
        }
        return HTTPResponse(
            statusCode: status,
            headers: ["Content-Type": "application/json"],
            body: Data(body.utf8)
        )
    }
}
