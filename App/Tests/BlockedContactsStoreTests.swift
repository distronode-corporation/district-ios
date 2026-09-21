@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The shared blocked set, which is the only piece of App-target logic the
/// Guideline 1.2 block relies on.
///
/// ⛔ IT IS TESTED HERE BECAUSE IT CANNOT LIVE IN `DistrictCore`. The store is
/// `@MainActor @Observable`, four SwiftUI screens in three tabs read it, and its whole
/// job is that the screen that performs a block and the screen that must stop showing
/// the content agree without a round trip. `project.yml`'s rule is that logic which
/// CAN live in the package does; this cannot.
///
/// ⛔ THE ONE BEHAVIOUR WORTH THE MOST HERE IS THE WORKSPACE GUARD. A set loaded for
/// one tenant must not be read as another's: `isBlocked` answers FALSE for a workspace
/// it has not loaded rather than reporting a stale membership, because the alternative
/// is badging a caller in a workspace that never blocked them.
@MainActor
final class BlockedContactsStoreTests: XCTestCase {
    func testTheStoreIsEmptyAndClaimsNoWorkspaceBeforeAnyRead() {
        let store = BlockedContactsStore(contacts: ContactsRepository(client: Self.client(Self.empty)))

        XCTAssertTrue(store.blockedContactIds.isEmpty)
        XCTAssertNil(store.loadedWorkspaceId)
        XCTAssertFalse(store.isBlocked("c_1", in: "ws_1"))
    }

    func testARefreshAdoptsTheLiveBlocksAndClaimsTheWorkspace() async {
        let store = BlockedContactsStore(contacts: ContactsRepository(client: Self.client(Self.twoBlocked)))

        await store.refresh(workspaceId: "ws_1")

        XCTAssertEqual(store.blockedContactIds, ["c_1", "c_2"])
        XCTAssertEqual(store.loadedWorkspaceId, "ws_1")
        XCTAssertTrue(store.isBlocked("c_1", in: "ws_1"))
    }

    /// ⛔ A ROW WITH A NULL `blockedAt` IS NOT A BLOCK. The repository returns rows as
    /// the server sent them (it is the authority on which of its own rows count), so
    /// the filter is here — and without it the badge would appear on a caller who is
    /// not blocked.
    func testARowWithNoTimestampIsNotTreatedAsBlocked() async {
        let store = BlockedContactsStore(contacts: ContactsRepository(client: Self.client(Self.oneStale)))

        await store.refresh(workspaceId: "ws_1")

        XCTAssertEqual(store.blockedContactIds, ["c_live"])
        XCTAssertFalse(store.isBlocked("c_stale", in: "ws_1"))
    }

    /// ⛔ THE WORKSPACE GUARD. A set loaded for `ws_1` must never answer for `ws_2`:
    /// the store outlives a workspace switch (the screens are rebuilt, it is not), and
    /// "I do not know" must not read as "blocked".
    func testTheSetIsNotReadAcrossWorkspaces() async {
        let store = BlockedContactsStore(contacts: ContactsRepository(client: Self.client(Self.twoBlocked)))

        await store.refresh(workspaceId: "ws_1")

        XCTAssertTrue(store.isBlocked("c_1", in: "ws_1"))
        XCTAssertFalse(store.isBlocked("c_1", in: "ws_2"))
    }

    /// ⛔ A FAILED READ LEAVES THE PREVIOUS SET IN PLACE AND SAYS NOTHING. It is a read
    /// nobody asked for (it runs when a list appears), so a sentence would land on a
    /// screen whose actual content loaded fine — and clearing the set would take a
    /// Blocked badge off a caller who is still blocked.
    func testAFailedRefreshKeepsThePreviousSetAndReportsNothing() async {
        let transport = AppTestTransport([
            Self.response(Self.twoBlocked),
            Self.response(#"{"success":false,"error":"nope"}"#, status: 503),
        ])
        let store = BlockedContactsStore(contacts: ContactsRepository(client: Self.client(transport)))

        await store.refresh(workspaceId: "ws_1")
        await store.refresh(workspaceId: "ws_1")

        XCTAssertEqual(store.blockedContactIds, ["c_1", "c_2"])
        XCTAssertNil(store.failure)
    }

    // MARK: - Writes

    /// ⛔ THE REPLY IS ADOPTED, NOT THE REQUEST. A block asked for by NUMBER answers a
    /// `contactId` the caller had never seen, because the server upserts the row —
    /// recording the requested value instead would leave the badge and the database
    /// free to disagree.
    func testABlockByNumberAdoptsTheContactIdTheServerAnswered() async {
        let body = #"""
        {"success":true,"contactId":"c_upserted","name":"Casey","phoneNumber":"+15550101",
         "blockedAt":"2026-09-16T14:02:00.000Z"}
        """#
        let store = BlockedContactsStore(contacts: ContactsRepository(client: Self.client(body)))

        let ok = await store.setBlocked(
            workspaceId: "ws_1",
            subject: .phoneNumber("+15550101"),
            blocked: true
        )

        XCTAssertTrue(ok)
        XCTAssertEqual(store.blockedContactIds, ["c_upserted"])
        XCTAssertTrue(store.isBlocked("c_upserted", in: "ws_1"))
    }

    /// ⛔ A BLOCK CLAIMS THE WORKSPACE EVEN WITH NO LIST READ BEHIND IT, which is what
    /// makes the badge appear on a thread opened straight from a push notification —
    /// the "immediately" Guideline 1.2 asks about.
    func testABlockMakesTheStateVisibleWithNoPriorRead() async {
        let store = BlockedContactsStore(contacts: ContactsRepository(client: Self.client(Self.blocked)))

        _ = await store.setBlocked(workspaceId: "ws_9", subject: .contact("c_1"), blocked: true)

        XCTAssertEqual(store.loadedWorkspaceId, "ws_9")
        XCTAssertTrue(store.isBlocked("c_1", in: "ws_9"))
    }

    /// ⛔ AN UNBLOCK REMOVES THE ROW RATHER THAN ADDING ONE. The route answers
    /// `blockedAt: null`, and a client that keyed on "the write succeeded" instead of
    /// on the answered state would badge a caller it had just let back in.
    func testAnUnblockRemovesTheContactFromTheSet() async {
        let transport = AppTestTransport([
            Self.response(Self.blocked),
            Self.response(Self.unblocked),
        ])
        let store = BlockedContactsStore(contacts: ContactsRepository(client: Self.client(transport)))

        _ = await store.setBlocked(workspaceId: "ws_1", subject: .contact("c_1"), blocked: true)
        _ = await store.setBlocked(workspaceId: "ws_1", subject: .contact("c_1"), blocked: false)

        XCTAssertTrue(store.blockedContactIds.isEmpty)
        XCTAssertFalse(store.isBlocked("c_1", in: "ws_1"))
    }

    /// ⛔ A BLOCK PERFORMED IN A DIFFERENT WORKSPACE DISCARDS THE OLD SET RATHER THAN
    /// MERGING INTO IT. Contact ids are per-tenant; a merged set would answer for a
    /// row in the wrong workspace.
    func testABlockInAnotherWorkspaceReplacesTheSetRatherThanMerging() async {
        let transport = AppTestTransport([
            Self.response(Self.twoBlocked),
            Self.response(Self.blocked),
        ])
        let store = BlockedContactsStore(contacts: ContactsRepository(client: Self.client(transport)))

        await store.refresh(workspaceId: "ws_1")
        _ = await store.setBlocked(workspaceId: "ws_2", subject: .contact("c_1"), blocked: true)

        XCTAssertEqual(store.loadedWorkspaceId, "ws_2")
        XCTAssertEqual(store.blockedContactIds, ["c_1"])
        XCTAssertFalse(store.isBlocked("c_2", in: "ws_2"))
    }

    /// ⚠️ A FAILED WRITE **DOES** REPORT, unlike a failed read: the operator asked for
    /// it, so the server's own sentence has to reach a screen. And the set does not
    /// move.
    func testAFailedWriteReportsAndLeavesTheSetAlone() async {
        let store = BlockedContactsStore(
            contacts: ContactsRepository(
                client: Self.client(AppTestTransport([
                    Self.response(#"{"error":"Insufficient role for this workspace."}"#, status: 403),
                ]))
            )
        )

        let ok = await store.setBlocked(workspaceId: "ws_1", subject: .contact("c_1"), blocked: true)

        XCTAssertFalse(ok)
        XCTAssertEqual(store.failure?.message, "Insufficient role for this workspace.")
        XCTAssertTrue(store.blockedContactIds.isEmpty)

        store.clearFailure()
        XCTAssertNil(store.failure)
    }

    // MARK: - Conversations

    /// ⛔ FALSE FOR A THREAD WITH NO `contactId`. An address-keyed thread has nothing
    /// to compare, and normalising the address here would be a SECOND normaliser that
    /// could disagree with the server's, and two sides that normalise differently make
    /// a read silently return nothing.
    func testAnAddressKeyedThreadIsNeverFilteredOut() async {
        let store = BlockedContactsStore(contacts: ContactsRepository(client: Self.client(Self.blocked)))
        _ = await store.setBlocked(workspaceId: "ws_1", subject: .phoneNumber("+15550101"), blocked: true)

        XCTAssertFalse(store.isBlocked(conversation: Self.conversation(contactId: nil), in: "ws_1"))
    }

    func testAContactKeyedThreadForABlockedCallerIsFilteredOut() async {
        let store = BlockedContactsStore(contacts: ContactsRepository(client: Self.client(Self.blocked)))
        _ = await store.setBlocked(workspaceId: "ws_1", subject: .contact("c_1"), blocked: true)

        XCTAssertTrue(store.isBlocked(conversation: Self.conversation(contactId: "c_1"), in: "ws_1"))
        XCTAssertFalse(store.isBlocked(conversation: Self.conversation(contactId: "c_other"), in: "ws_1"))
    }

    // MARK: - Fixtures

    private static let blocked = #"""
    {"success":true,"contactId":"c_1","name":"Casey","phoneNumber":"+15550101",
     "blockedAt":"2026-09-16T14:02:00.000Z"}
    """#

    private static let unblocked = #"""
    {"success":true,"contactId":"c_1","name":"Casey","phoneNumber":"+15550101","blockedAt":null}
    """#

    private static let empty = #"{"success":true,"blocked":[]}"#

    private static let twoBlocked = #"""
    {"success":true,"blocked":[
      {"contactId":"c_1","name":"Casey","phoneNumber":"+15550101","blockedAt":"2026-09-16T14:02:00.000Z"},
      {"contactId":"c_2","name":"ada@example.com","phoneNumber":null,"blockedAt":"2026-09-16T14:03:00.000Z"}
    ]}
    """#

    private static let oneStale = #"""
    {"success":true,"blocked":[
      {"contactId":"c_live","name":"Casey","phoneNumber":"+15550101","blockedAt":"2026-09-16T14:02:00.000Z"},
      {"contactId":"c_stale","name":"Jordan","phoneNumber":"+15550102","blockedAt":null}
    ]}
    """#

    /// ⚠️ DECODED FROM JSON RATHER THAN CONSTRUCTED. `ConversationSummary`'s
    /// memberwise initialiser is internal to `DistrictModel`, and making it public so
    /// a test could call it would add public API nothing in the app uses — which under
    /// the package's own 100% coverage floor is a surface no test exercises. Same call
    /// `DeskBodies` records for `DeskTicketSummary`.
    private static func conversation(contactId: String?) -> ConversationSummary {
        let id = contactId.map { #""\#($0)""# } ?? "null"
        let body = #"""
        {"key":"k","threadKey":"contact:x","counterpart":"+15550101","matchKeys":["15550101"],
         "kind":"sms","channels":["sms"],"contactId":\#(id),"contactName":"Casey",
         "contactEmail":null,"contactPhone":"+15550101","canSms":true,"canEmail":false,
         "lastMessage":{"body":"hi","direction":"inbound","type":null,"status":"received",
         "createdAt":"2026-09-16T14:00:00.000Z"},"unreadCount":0,"totalMessages":1}
        """#
        // ⚠️ FORCE-DECODED IN TEST CODE ONLY. A malformed literal here is a broken
        // test rather than a product defect, and the crash names the line.
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(ConversationSummary.self, from: Data(body.utf8))
    }

    private static func response(_ json: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(
            statusCode: status,
            headers: ["Content-Type": "application/json"],
            body: Data(json.utf8)
        )
    }

    private static func client(_ json: String) -> ApiClient {
        client(AppTestTransport([response(json)]))
    }

    private static func client(_ transport: AppTestTransport) -> ApiClient {
        ApiClient(
            baseURL: ApiClient.productionBaseURL,
            transport: transport,
            accessToken: { "session-token" }
        )
    }
}

/// A queue of canned responses.
///
/// ⚠️ A THIRD COPY OF THIS DOUBLE, and the reason is the same one
/// `RepositoryTransport`'s own ⚠️ gives: SwiftPM test targets do not share code and a
/// shared helper would have to be a PRODUCT of the package. This one is in the App
/// bundle, which cannot see either of the other two at all.
final class AppTestTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [HTTPResponse]
    private(set) var requests: [HTTPRequest] = []

    init(_ responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest, followRedirects: Bool) async throws -> HTTPResponse {
        _ = followRedirects
        let next: HTTPResponse? = lock.withLock {
            requests.append(request)
            guard !responses.isEmpty else { return nil }
            return responses.removeFirst()
        }
        guard let next else {
            throw URLError(.badServerResponse)
        }
        return next
    }
}
