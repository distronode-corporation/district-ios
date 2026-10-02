@testable import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The Inbox repository: the thread list, one thread's cursor, the composer's
/// persistence, and the three writes that spend money.
///
/// ⚠️ A FILE OF ITS OWN BECAUSE OF SIZE, NOT KIND. `RepositoryTests` sits at 478 of
/// SwiftLint's 500-line ceiling and the composer alone is seven methods. The
/// `JSONValue` → ``ThreadPage`` mapping the timeline read hands off to is in
/// `ThreadPageReaderTests`.
final class InboxRepositoryTests: XCTestCase {
    // MARK: - The thread list

    /// ⛔ `scanned == scanLimit` MEANS THE WINDOW WAS FULL AND OLDER THREADS EXIST.
    /// Nothing is broken and there is nothing to fetch, but a partial list
    /// presented as the whole inbox is the same class of lie as an empty list on a
    /// failed read.
    func testAFullScanWindowMarksTheConversationListPartial() async {
        let body = Bodies.conversations([Bodies.conversation(threadKey: "contact:c_1")], scanned: 500, scanLimit: 500)
        let transport = RepositoryTransport(json: body)

        let result = await InboxRepository(client: .repositoryTest(transport)).conversations(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.isPartial, true)
        XCTAssertEqual(result.successOnly?.conversations.map(\.threadKey), ["contact:c_1"])
    }

    func testAnUnfilledScanWindowIsNotPartial() async {
        let body = Bodies.conversations([Bodies.conversation(threadKey: "contact:c_1")], scanned: 12, scanLimit: 500)
        let transport = RepositoryTransport(json: body)

        let result = await InboxRepository(client: .repositoryTest(transport)).conversations(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.isPartial, false)
    }

    /// ⛔ THE CASE THE TYPE ALONE CANNOT CATCH: every required key present and the
    /// flag false. Without the envelope guard that renders as an empty inbox.
    func testAConversationListThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let body = Bodies.conversations([]).replacingOccurrences(of: #""success":true"#, with: #""success":false"#)
        let transport = RepositoryTransport(json: body)

        let result = await InboxRepository(client: .repositoryTest(transport)).conversations(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly, .decoding("ConversationsResponse did not affirm success=true"))
    }

    // MARK: - One thread's history

    /// ⛔ OMITTING BOTH CURSOR ARGUMENTS IS THE NEWEST WINDOW, byte for byte the
    /// request this made before paging existed. `before=` present-but-empty becomes
    /// `new Date("")` server-side and the route answers 400 — every thread open
    /// would break.
    func testANoCursorTimelineReadSendsNoCursorParameters() async {
        let transport = RepositoryTransport(json: Self.oneRowTimeline)

        let result = await InboxRepository(client: .repositoryTest(transport))
            .timeline(workspaceId: "ws_1", selector: .contact("c_1"))

        XCTAssertEqual(result.successOnly?.events.map(\.id), ["m_1"])
        XCTAssertEqual(result.successOnly?.hasMore, false)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/timeline?workspaceId=ws_1&contactId=c_1"
        )
    }

    /// ⚠️ THE ADDRESS PARAMETER IS STILL SPELLED `phoneNumber` ON THE WIRE and now
    /// carries an email too. Renaming it would 400. ⚠️ And the `+` is percent-encoded
    /// rather than left literal: a permissive encoder turns it into a SPACE after
    /// the server's own form decoding, and the thread comes back empty.
    func testAnAddressSelectorTravelsAsPhoneNumber() async {
        let transport = RepositoryTransport(json: Self.oneRowTimeline)

        _ = await InboxRepository(client: .repositoryTest(transport))
            .timeline(workspaceId: "ws_1", selector: .address("+14165550134"))

        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/timeline?workspaceId=ws_1&phoneNumber=%2B14165550134"
        )
    }

    /// ⛔ THE CURSOR IS A PAIR OR NOTHING. `beforeId` without `before` is a 400 —
    /// an id alone cannot say which timestamp it breaks a tie at — which is why
    /// ``ThreadCursor`` cannot hold half of itself.
    func testACursorSendsBothHalvesTogether() async {
        let transport = RepositoryTransport(json: Self.oneRowTimeline)
        let cursor = ThreadCursor(before: "2026-08-19T09:41:00.000Z", beforeId: "m_9")

        _ = await InboxRepository(client: .repositoryTest(transport))
            .timeline(workspaceId: "ws_1", selector: .contact("c_1"), cursor: cursor)

        let expected = "https://www.distronode.com/api/district/timeline?workspaceId=ws_1&contactId=c_1"
            + "&before=2026-08-19T09%3A41%3A00.000Z&beforeId=m_9"
        XCTAssertEqual(transport.requestedURLs.first, expected)
    }

    func testATimelineThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false,"timeline":[]}"#)

        let result = await InboxRepository(client: .repositoryTest(transport))
            .timeline(workspaceId: "ws_1", selector: .contact("c_1"))

        XCTAssertEqual(result.failureOnly, .decoding("TimelineResponse did not affirm success=true"))
    }

    /// ⚠️ A SEPARATE CALL FROM THE LIST ON PURPOSE: the nav badge needs this number
    /// without paying for the 500-message scan.
    func testTheUnreadCountDecodesTyped() async {
        let transport = RepositoryTransport(json: #"{"success":true,"count":4,"workspaceId":"ws_1"}"#)

        let result = await InboxRepository(client: .repositoryTest(transport)).unreadCount(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.count, 4)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/messages/unread-count?workspaceId=ws_1"
        )
    }

    /// ⛔ THE CASE THE TYPE ALONE CANNOT CATCH. `count` is non-optional, so `{}` is
    /// rejected anyway and a missing envelope check reads as harmless; but a
    /// well-formed body carrying `success:false` decodes cleanly and the badge
    /// paints the 7. ⚠️ The count is
    /// deliberately NON-ZERO here: a fixture answering `0` would pass against the
    /// broken code too, which is exactly how a happy-path-only test misses this.
    func testAnUnreadCountThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false,"count":7,"workspaceId":"ws_1"}"#)

        let result = await InboxRepository(client: .repositoryTest(transport)).unreadCount(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly, .decoding("UnreadCountResponse did not affirm success=true"))
        XCTAssertNil(result.successOnly, "an unaffirmed envelope must not hand a count back to the badge")
    }

    // MARK: - Drafts (persistence)

    /// ⛔ nil IS THE ORDINARY ANSWER AND NOT A FAILURE. The server answers
    /// `{success, draft: null}` rather than 404 precisely so the composer's normal
    /// open path is not an error in every log.
    func testAThreadWithNoDraftIsNilRatherThanAFailure() async throws {
        let transport = RepositoryTransport(json: #"{"success":true,"draft":null}"#)

        let result = await InboxRepository(client: .repositoryTest(transport))
            .draft(workspaceId: "ws_1", threadKey: "contact:c_1")

        XCTAssertNil(result.failureOnly, "a null draft is the ordinary answer and must not read as a failure")
        let restored = try XCTUnwrap(result.successOnly, "the read itself succeeded")
        XCTAssertNil(restored)
    }

    /// ⛔ THE PLURAL, CHEAP PATH — with BOTH parameters. The same path without
    /// `threadKey` is the LIST endpoint, which decodes as a draft-less response and
    /// silently restores nothing.
    func testASavedDraftIsRestoredFromThePluralPath() async throws {
        let body = #"{"success":true,"draft":\#(Bodies.draft(threadKey: "contact:c_1"))}"#
        let transport = RepositoryTransport(json: body)

        let result = await InboxRepository(client: .repositoryTest(transport))
            .draft(workspaceId: "ws_1", threadKey: "contact:c_1")

        let restored = try XCTUnwrap(result.successOnly)
        XCTAssertEqual(restored?.body, "Thanks, booking that now.")
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/messages/drafts?workspaceId=ws_1&threadKey=contact%3Ac_1"
        )
    }

    /// ⚠️ READ ONCE PER INBOX LOAD TO BADGE THE LIST, NOT PER ROW — one indexed
    /// query against one request per visible conversation.
    func testTheDraftsListIsReadOncePerInboxLoad() async {
        let body = #"{"success":true,"drafts":[\#(Bodies.draft(threadKey: "contact:c_1"))]}"#
        let transport = RepositoryTransport(json: body)

        let result = await InboxRepository(client: .repositoryTest(transport)).drafts(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.map(\.threadKey), ["contact:c_1"])
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/messages/drafts?workspaceId=ws_1"
        )
    }

    /// ⛔ REFUSED LOCALLY, AND NOTHING IS SENT. The route answers 400 `empty_body`
    /// and means "send DELETE instead"; doing that substitution silently here would
    /// hide the bug until an offline queue replayed the two writes out of order.
    /// ⚠️ Whitespace counts as blank — a composer cleared to a stray space is still
    /// the absence of a draft.
    func testABlankDraftIsRefusedLocallyWithoutSpendingTheRoundTrip() async {
        let transport = RepositoryTransport(queue: [])
        let repository = InboxRepository(client: .repositoryTest(transport))

        let empty = await repository.saveDraft(workspaceId: "ws_1", threadKey: "contact:c_1", body: "")
        let spaces = await repository.saveDraft(workspaceId: "ws_1", threadKey: "contact:c_1", body: " \n\t")

        let refusal = ApiError.http(status: 400, message: "A draft cannot be blank. Delete it instead.")
        XCTAssertEqual(empty.failureOnly, refusal)
        XCTAssertEqual(spaces.failureOnly, refusal)
        XCTAssertTrue(transport.requestedURLs.isEmpty, "a locally-refused draft must not reach the network")
    }

    /// ⛔ **PUT, NOT POST**, on the plural path. The route exports GET/PUT/DELETE
    /// only and a POST there is a 405.
    func testSavingADraftUsesPutOnThePluralPath() async throws {
        let body = #"{"success":true,"draft":\#(Bodies.draft(threadKey: "contact:c_1", body: "On our way."))}"#
        let transport = RepositoryTransport(json: body)

        let result = await InboxRepository(client: .repositoryTest(transport))
            .saveDraft(workspaceId: "ws_1", threadKey: "contact:c_1", body: "On our way.")

        let saved = try XCTUnwrap(result.successOnly)
        XCTAssertEqual(saved?.body, "On our way.")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, .put)
        XCTAssertEqual(request.url.absoluteString, "https://www.distronode.com/api/district/messages/drafts")
    }

    /// ⚠️ IDEMPOTENT, AND THE RESPONSE IS DISCARDED DELIBERATELY — what matters is
    /// whether the write landed, not what it echoed.
    func testDeletingADraftIsIdempotentAndDiscardsTheBody() async throws {
        let transport = RepositoryTransport(json: #"{"success":true,"deleted":0}"#)

        let result = await InboxRepository(client: .repositoryTest(transport))
            .deleteDraft(workspaceId: "ws_1", threadKey: "contact:c_1")

        XCTAssertNil(result.failureOnly)
        XCTAssertEqual(try XCTUnwrap(transport.requests.first).method, .delete)
    }

    // MARK: - The writes that cost money

    /// ⛔ THE SINGULAR PATH IS ONE VERTEX GENERATION PER CALL, one letter from the
    /// plural persistence route. ⚠️ An empty generation is a legitimate answer and
    /// must not blank a composer the operator has already typed in.
    func testTheBilledGeneratorUsesTheSingularPathAndMayAnswerEmpty() async {
        let transport = RepositoryTransport(json: #"{"success":true,"draft":""}"#)

        let result = await InboxRepository(client: .repositoryTest(transport))
            .generateDraft(workspaceId: "ws_1", selector: .contact("c_1"))

        XCTAssertEqual(result.successOnly, "")
        XCTAssertEqual(transport.requestedURLs.first, "https://www.distronode.com/api/district/messages/draft")
    }

    /// ⛔ THE RECIPIENT IS AN ADDRESS, NEVER A THREAD IDENTITY. `to` goes straight
    /// to the carrier; sending `contact:<id>` dispatches an SMS to a cuid and fails
    /// at the provider as a raw 500 — and that is MOST threads.
    func testSendingUsesTheResolvedReplyTargetNotTheThreadIdentity() async throws {
        let transport = RepositoryTransport(json: Bodies.sentSms())
        let row = try conversation(Bodies.conversation(threadKey: "contact:c_1", contactId: "c_1"))
        let target = try XCTUnwrap(row.replyTarget)

        let result = await InboxRepository(client: .repositoryTest(transport))
            .send(workspaceId: "ws_1", target: target, body: "On our way.")

        XCTAssertEqual(target.channel, MessageChannel.sms)
        XCTAssertEqual(result.successOnly?.to, "+14165550134")
        XCTAssertEqual(result.successOnly?.status, "queued")
    }

    /// ⚠️ THE RESULT IS A COUNT AND ZERO IS A SUCCESS: a thread another agent
    /// already opened marks nothing. Both outcomes redraw from the list.
    func testMarkingReadCarriesTheCountAndZeroIsASuccess() async {
        let transport = RepositoryTransport(queue: [#"{"success":true,"marked":3}"#, #"{"success":true,"marked":0}"#])
        let repository = InboxRepository(client: .repositoryTest(transport))

        let first = await repository.markRead(workspaceId: "ws_1", selector: .contact("c_1"))
        let again = await repository.markRead(workspaceId: "ws_1", selector: .address("+14165550134"))

        XCTAssertEqual(first.successOnly, 3)
        XCTAssertEqual(again.successOnly, 0)
    }

    // MARK: - Attachments

    /// ⚠️ REFUSED BEFORE IT IS SENT. Five megabytes spent on a metered connection to
    /// be told the same thing is the cost of trusting the round trip.
    func testAnOversizedAttachmentIsRefusedBeforeItIsSent() async {
        let transport = RepositoryTransport(queue: [])
        let oversized = Data(count: MediaUploadLimits.maximumByteCount + 1)

        let result = await InboxRepository(client: .repositoryTest(transport))
            .uploadMedia(workspaceId: "ws_1", fileName: "a.png", mimeType: "image/png", bytes: oversized)

        XCTAssertEqual(result.failureOnly?.message, "Attachments must be 5 MB or smaller.")
        XCTAssertTrue(transport.requestedURLs.isEmpty)
    }

    /// ⚠️ THE OTHER TWO REFUSALS, ASSERTED ON THE MIRROR ITSELF. The server enforces
    /// these and its answer wins; this constant only buys latency.
    func testTheUnsupportedTypeAndEmptyFileRefusalsAreDistinct() {
        XCTAssertEqual(
            MediaUploadLimits.refusal(mimeType: "application/pdf", byteCount: 10)?.message,
            "Attachments must be a JPEG, PNG, GIF or WebP image."
        )
        XCTAssertEqual(MediaUploadLimits.refusal(mimeType: "image/gif", byteCount: 0)?.message, "That file is empty.")
        XCTAssertNil(MediaUploadLimits.refusal(mimeType: "image/webp", byteCount: 1))
        XCTAssertEqual(MediaUploadLimits.allowedMimeTypes.count, 4)
    }

    /// ⛔ THE URL IT RETURNS IS AN ANONYMOUS CAPABILITY URL and must be loaded back
    /// WITHOUT this client's bearer token — a carrier's MMS fetcher has no session
    /// either, and attaching one would send a credential to a route that does not
    /// need it.
    func testAnAcceptedAttachmentReturnsTheAnonymousCapabilityUrl() async {
        let body = #"""
        {"success":true,"media":{"id":"med_1","mimeType":"image/png","sizeBytes":12,
         "url":"https://www.distronode.com/api/media/med_1"}}
        """#
        let transport = RepositoryTransport(json: body)

        let result = await InboxRepository(client: .repositoryTest(transport))
            .uploadMedia(workspaceId: "ws_1", fileName: "a.png", mimeType: "image/png", bytes: Data([1, 2, 3]))

        XCTAssertEqual(result.successOnly?.url, "https://www.distronode.com/api/media/med_1")
        XCTAssertEqual(transport.requestedURLs.first, "https://www.distronode.com/api/district/messages/media")
    }

    // MARK: - Helpers

    /// The smallest valid timeline response: one row carrying only the two fields
    /// a thread entry cannot be rendered without.
    private static let oneRowTimeline = #"""
    {"success":true,"timeline":[{"id":"m_1","timestamp":"2026-08-19T09:41:00.000Z"}]}
    """#

    /// ⚠️ DECODED DIRECTLY RATHER THAN READ BACK THROUGH THE REPOSITORY, so a
    /// selector or reply-target assertion fails on the thing it is about instead of
    /// on an unrelated envelope change.
    private func conversation(_ json: String) throws -> ConversationSummary {
        try JSONDecoder().decode(ConversationSummary.self, from: Data(json.utf8))
    }
}
