@testable import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The message-to-thread resolver, and the workspace-wide mark-read beside it.
///
/// ⚠️ A FILE OF ITS OWN BECAUSE `InboxRepositoryTests` IS THE LARGE ONE ALREADY, and
/// because these two calls answer a different question from the rest of that suite:
/// everything there starts from a thread the operator is looking at, and everything
/// here starts from a push payload that names a MESSAGE and nothing else.
///
/// ⛔ THE ADDRESS-KEYED BRANCH IS DECODED FROM BYTES RATHER THAN FROM A FIXTURE, and
/// that is a property of the corpus rather than a lowered bar.
/// `district-message-thread.json` is contact-keyed, so the `addr:<key>` /
/// `contactId: null` shape — a stranger who has just written in, which is the common
/// case for a FIRST inbound message and therefore for most pushes — has no committed
/// document. The corpus belongs to the Android side, so the branch is pinned here
/// the way `district-draft-null.json`'s null draft is.
final class InboxThreadResolveTests: XCTestCase {
    // MARK: - Resolving a pushed message id

    /// ⛔ THE SELECTOR PREFERS THE CONTACT ID, AND THE FALLBACK IS THE COUNTERPART
    /// RATHER THAN THE THREAD KEY. `addr:<normalized>` sent whole as the address
    /// parameter matches nothing, so a `mark-read` built from it succeeds against
    /// ZERO rows and the badge never clears — the same trap
    /// ``ThreadSelector/forConversation(_:)`` documents from the list's side.
    func testAContactKeyedThreadResolvesToTheContactSelector() async {
        let transport = RepositoryTransport(json: Self.contactKeyed)

        let result = await InboxRepository(client: .repositoryTest(transport))
            .messageThread(workspaceId: "ws_1", messageId: "msg_1")

        XCTAssertEqual(result.successOnly?.threadKey, "contact:c_1")
        XCTAssertEqual(result.successOnly?.selector, .contact("c_1"))
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/messages/msg_1?workspaceId=ws_1"
        )
        XCTAssertTrue(transport.bodies.isEmpty, "a GET carries no body")
    }

    /// ⛔ AND AN ADDRESS-KEYED THREAD FALLS BACK TO THE COUNTERPART, NOT TO
    /// `addr:14165550134`. This is the ordinary shape for the first message from
    /// somebody who is not a contact yet, which is most of what a push is about.
    func testAnAddressKeyedThreadResolvesToTheCounterpartSelector() async {
        let transport = RepositoryTransport(json: Self.addressKeyed)

        let result = await InboxRepository(client: .repositoryTest(transport))
            .messageThread(workspaceId: "ws_1", messageId: "msg_2")

        XCTAssertEqual(result.successOnly?.threadKey, "addr:14165550134")
        XCTAssertEqual(result.successOnly?.selector, .address("+14165550134"))
    }

    /// ⚠️ A PRESENT-BUT-BLANK CONTACT ID IS NOT A CONTACT ID. It would reach the
    /// route as `contactId=`, which is a different instruction from omitting it, and
    /// the route's own `if (contact)` lookup would then find nothing and mark zero
    /// rows while the request looked perfectly well formed.
    func testABlankContactIdFallsBackToTheCounterpart() async {
        let transport = RepositoryTransport(json: Self.blankContactId)

        let result = await InboxRepository(client: .repositoryTest(transport))
            .messageThread(workspaceId: "ws_1", messageId: "msg_3")

        XCTAssertEqual(result.successOnly?.selector, .address("+14165550134"))
    }

    /// ⛔ THE REPLY TARGET IS THE ROUTE'S UNWRAPPED ADDRESS AND MUST TRAVEL VERBATIM.
    /// Inbound email `from` frequently carries a display-name wrapper, and the route
    /// runs `normalizeAddress` precisely so `Paul <paul@example.com>` cannot end up
    /// in `to` on a send. A client that re-derived anything from this string is how
    /// the wrapper comes back.
    func testTheReplyTargetIsTheUnwrappedAddressAndTheServersChannel() async {
        let transport = RepositoryTransport(json: Self.emailKeyed)

        let result = await InboxRepository(client: .repositoryTest(transport))
            .messageThread(workspaceId: "ws_1", messageId: "msg_4")

        XCTAssertEqual(result.successOnly?.replyTarget.to, "paul@example.com")
        XCTAssertEqual(result.successOnly?.replyTarget.channel, MessageChannel.email)
    }

    /// ⚠️ `readAt` IS WHAT LETS A SHADE DROP A "Mark read" THAT WOULD DO NOTHING. The
    /// inbox is workspace-level, so a colleague can open the thread between the push
    /// being sent and the notification being tapped. ⛔ It is not a guard: acting on a
    /// stale value costs one request that answers `marked: 0`, which is a success.
    func testTheReadFlagDistinguishesAnUnreadMessageFromOneAColleagueOpened() async {
        let unread = RepositoryTransport(json: Self.contactKeyed)
        let read = RepositoryTransport(json: Self.alreadyRead)
        let repository = InboxRepository(client: .repositoryTest(unread))

        let first = await repository.messageThread(workspaceId: "ws_1", messageId: "msg_1")
        let second = await InboxRepository(client: .repositoryTest(read))
            .messageThread(workspaceId: "ws_1", messageId: "msg_1")

        XCTAssertNotNil(first.successOnly, "an explicit null readAt decodes")
        XCTAssertNil(first.successOnly?.response.message.readAt, "an explicit null readAt is unread")
        XCTAssertNotNil(second.successOnly?.response.message.readAt)
    }

    /// ⚠️ `message.type` IS NULLABLE AND THE CHANNEL DOES NOT COME FROM IT. The column
    /// predates being written on every row, and the route falls back to the ADDRESS
    /// SHAPE rather than to a bare `"sms"` — telling a client to text an email address
    /// produces a send that fails at the provider with a message the operator wrote and
    /// cannot see. That fallback is the SERVER's; this only proves a null decodes.
    func testANullMessageTypeStillCarriesAServerChosenChannel() async {
        let transport = RepositoryTransport(json: Self.nullType)

        let result = await InboxRepository(client: .repositoryTest(transport))
            .messageThread(workspaceId: "ws_1", messageId: "msg_5")

        XCTAssertNil(result.successOnly?.response.message.type)
        XCTAssertEqual(result.successOnly?.replyTarget.channel, MessageChannel.email)
    }

    /// ⛔ THE CASE THE TYPE ALONE CANNOT CATCH: every required key present and the
    /// flag false. Without the envelope guard that resolves to a thread nobody
    /// looked up, and the deep link would open a conversation chosen by a handler
    /// that had already fallen into its own error branch.
    func testAThreadTargetThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let body = Self.contactKeyed.replacingOccurrences(of: #""success":true"#, with: #""success":false"#)
        let transport = RepositoryTransport(json: body)

        let result = await InboxRepository(client: .repositoryTest(transport))
            .messageThread(workspaceId: "ws_1", messageId: "msg_1")

        XCTAssertEqual(result.failureOnly, .decoding("MessageThreadResponse did not affirm success=true"))
    }

    // MARK: - The workspace-wide mark-read

    /// ⛔ `all: true` AND NO SELECTOR, ASSERTED ON THE BYTES. The route's own comment
    /// records the trap from the other side: a selector that resolved to nothing
    /// usable must mark ZERO rows, because falling through to an empty filter would
    /// mark the ENTIRE workspace read. So the two bodies are kept apart by two
    /// functions, and this is what proves neither carries the other's keys.
    func testMarkingEverythingReadSendsAllAndNoSelector() async throws {
        let transport = RepositoryTransport(json: #"{"success":true,"marked":12}"#)

        let result = await InboxRepository(client: .repositoryTest(transport)).markAllRead(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly, 12)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/messages/mark-read"
        )
        let body = try XCTUnwrap(transport.bodies.first)
        XCTAssertEqual(body, #"{"all":true,"workspaceId":"ws_1"}"#)
    }

    /// ⚠️ ZERO IS A SUCCESS AND IS THE HONEST ANSWER TO "there was nothing left to
    /// clear". Pressing the control twice is safe; the second press marks nothing and
    /// the caller redraws from the list either way.
    func testMarkingEverythingReadTwiceIsSafeAndTheSecondMarksNothing() async {
        let transport = RepositoryTransport(queue: [
            #"{"success":true,"marked":12}"#,
            #"{"success":true,"marked":0}"#,
        ])
        let repository = InboxRepository(client: .repositoryTest(transport))

        let first = await repository.markAllRead(workspaceId: "ws_1")
        let again = await repository.markAllRead(workspaceId: "ws_1")

        XCTAssertEqual(first.successOnly, 12)
        XCTAssertEqual(again.successOnly, 0)
    }

    /// ⛔ AND IT AFFIRMS THE ENVELOPE, like every other write on this repository. A
    /// `{"success":false,"marked":0}` decodes perfectly well, and adopting it would
    /// tell an operator the workspace was cleared by a handler that failed.
    func testAMarkAllReadBodyThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false,"marked":0}"#)

        let result = await InboxRepository(client: .repositoryTest(transport)).markAllRead(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly, .decoding("MarkReadResponse did not affirm success=true"))
    }

    // MARK: - Bodies

    /// ⚠️ THE FIXTURE'S OWN SHAPE, so a divergence between this file and
    /// `district-message-thread.json` shows up as one of the two failing rather than
    /// as both agreeing on something the server does not send.
    private static let contactKeyed = #"""
    {"success":true,
     "message":{"id":"msg_1","direction":"inbound","type":"sms","readAt":null,
                "createdAt":"2026-08-15T14:30:00.000Z"},
     "thread":{"threadKey":"contact:c_1","contactId":"c_1","counterpart":"+14165550134","channel":"sms"}}
    """#

    private static let addressKeyed = #"""
    {"success":true,
     "message":{"id":"msg_2","direction":"inbound","type":"sms","readAt":null,
                "createdAt":"2026-08-15T14:30:00.000Z"},
     "thread":{"threadKey":"addr:14165550134","contactId":null,"counterpart":"+14165550134","channel":"sms"}}
    """#

    private static let blankContactId = #"""
    {"success":true,
     "message":{"id":"msg_3","direction":"inbound","type":"sms","readAt":null,
                "createdAt":"2026-08-15T14:30:00.000Z"},
     "thread":{"threadKey":"addr:14165550134","contactId":"","counterpart":"+14165550134","channel":"sms"}}
    """#

    private static let emailKeyed = #"""
    {"success":true,
     "message":{"id":"msg_4","direction":"inbound","type":"email","readAt":null,
                "createdAt":"2026-08-15T14:30:00.000Z"},
     "thread":{"threadKey":"contact:c_2","contactId":"c_2","counterpart":"paul@example.com","channel":"email"}}
    """#

    private static let nullType = #"""
    {"success":true,
     "message":{"id":"msg_5","direction":"inbound","type":null,"readAt":null,
                "createdAt":"2026-08-15T14:30:00.000Z"},
     "thread":{"threadKey":"contact:c_2","contactId":"c_2","counterpart":"paul@example.com","channel":"email"}}
    """#

    private static let alreadyRead = #"""
    {"success":true,
     "message":{"id":"msg_1","direction":"inbound","type":"sms","readAt":"2026-08-15T14:31:00.000Z",
                "createdAt":"2026-08-15T14:30:00.000Z"},
     "thread":{"threadKey":"contact:c_1","contactId":"c_1","counterpart":"+14165550134","channel":"sms"}}
    """#
}
