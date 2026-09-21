import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The knowledge base's two reads and two writes.
///
/// ⛔ THE ASSERTIONS HERE ARE ABOUT OUTCOMES THAT LOOK ALIKE AND ARE NOT. An empty
/// document list and a failed read are the same picture on a screen and must not be
/// the same value; a create that answered `success: true` with no row is not a
/// document; and the mode route's ECHO is not the value that was asked for, which
/// is the whole reason this one write needs no re-read.
///
/// ⚠️ THE PATHS ARE ASSERTED BY STRING because `workspace/knowledge` and
/// `workspace/knowledge-mode` are one hyphenated suffix apart and share a prefix
/// with `workspace/knowledge/query`, which this client never calls. A typo would
/// present as a broken client rather than as a wrong URL.
final class KnowledgeRepositoryTests: XCTestCase {
    private func repository(_ transport: RepositoryTransport) -> KnowledgeRepository {
        KnowledgeRepository(client: .repositoryTest(transport))
    }

    // MARK: - The document list

    func testListingDocumentsGetsTheKnowledgeRouteAndAnswersTheRows() async {
        let transport = RepositoryTransport(json: KnowledgeBodies.list(ids: ["doc_a", "doc_b"]))

        let result = await repository(transport).documents(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.map(\.id), ["doc_a", "doc_b"])
        XCTAssertEqual(transport.requests.first?.method, .get)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/knowledge?workspaceId=ws_1"
        )
        XCTAssertTrue(transport.bodies.isEmpty, "a GET carries no body")
    }

    /// ⛔ AN EMPTY LIST IS A SUCCESS AND MUST STAY ONE. It is a workspace that has
    /// uploaded nothing, which is where every workspace starts; mapping it to a
    /// failure would show an error on the one screen whose job is to offer the
    /// upload button.
    func testAnEmptyDocumentListIsASuccessRatherThanAFailure() async {
        let transport = RepositoryTransport(json: #"{"success":true,"documents":[]}"#)

        let result = await repository(transport).documents(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly?.isEmpty, true)
        XCTAssertNil(result.failureOnly)
    }

    /// ⛔ THE ENVELOPE CHECK IS NOT REDUNDANT WITH THE DTO'S REQUIRED FIELDS. A
    /// required field rejects `{}`; it does not reject a well-formed body that says
    /// `success: false`, which is what this route's catch branch produces on a 200
    /// once the headers are written. Without it, "we could not look" renders as
    /// "you have uploaded nothing" and the operator uploads it again, at a second
    /// embedding bill.
    func testADocumentListThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false,"documents":[]}"#)

        let result = await repository(transport).documents(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly, .decoding("KnowledgeListResponse did not affirm success=true"))
    }

    /// ⚠️ THE PASTED ROW'S NULL `sourceUrl` HAS TO SURVIVE AS nil rather than as an
    /// empty string: "typed in by hand" and "imported from a blank URL" are different
    /// facts, and only the first one exists.
    func testAPastedDocumentKeepsItsNullSourceAsNil() async {
        let transport = RepositoryTransport(json: KnowledgeBodies.list(ids: ["doc_a"], sourced: false))

        let result = await repository(transport).documents(workspaceId: "ws_1")

        let document = result.successOnly?.first
        XCTAssertEqual(document?.sourceType, "text")
        XCTAssertNil(document?.sourceUrl)
        XCTAssertEqual(document?.status, "ready")
    }

    /// ⚠️ A `viewer` MAY READ THIS, and a 403 therefore means something else on this
    /// surface than it does on the writes: the caller is not a member at all, or the
    /// workspace id is not theirs. ⛔ The 401 and the 503 are the two it must be told
    /// apart from, one ending the session and the other worth retrying.
    func testARefusedListAndAnOutageKeepTheirStatuses() async {
        let forbidden = RepositoryTransport(json: #"{"success":false,"error":"Forbidden"}"#, status: 403)
        let refused = await repository(forbidden).documents(workspaceId: "ws_1")
        XCTAssertEqual(refused.failureOnly, .http(status: 403, message: "Forbidden"))

        let expired = RepositoryTransport(json: #"{"error":"Unauthorized"}"#, status: 401)
        let unauthorized = await repository(expired).documents(workspaceId: "ws_1")
        XCTAssertEqual(unauthorized.failureOnly?.isUnauthorized, true)

        let degraded = RepositoryTransport(json: #"{"success":false,"error":"Try again"}"#, status: 503)
        let transient = await repository(degraded).documents(workspaceId: "ws_1")
        XCTAssertEqual(transient.failureOnly?.httpStatus, 503)
        XCTAssertNil(transient.successOnly)
    }

    // MARK: - Ingesting a document

    /// ⛔ ONE CALL AND NOTHING ELSE, ASSERTED AS A COUNT. This is the only route in
    /// this client that spends Vertex embedding budget, the caller sizes the bill,
    /// and it is not idempotent: a retry pays twice for a duplicate document. The
    /// tempting shape for a slow write is "send it again", and that is exactly what
    /// must not be here.
    func testCreatingADocumentPostsOnceAndAnswersTheEchoedRow() async {
        let transport = RepositoryTransport(json: KnowledgeBodies.created)

        let result = await repository(transport).addDocument(
            workspaceId: "ws_1",
            title: "Holiday hours",
            content: "We are closed on the 25th."
        )

        XCTAssertEqual(result.successOnly?.id, "doc_new")
        XCTAssertEqual(result.successOnly?.chunkCount, 2)
        XCTAssertNil(result.successOnly?.sourceUrl, "⚠️ the create echo does not select it")
        XCTAssertEqual(transport.requests.count, 1, "no retry, ever: one call is one embedding bill")
        XCTAssertEqual(transport.requests.first?.method, .post)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/knowledge"
        )
        XCTAssertEqual(
            transport.bodies.first,
            #"{"content":"We are closed on the 25th.","title":"Holiday hours","workspaceId":"ws_1"}"#
        )
    }

    /// ⚠️ THE TWO OPTIONAL FIELDS REACH THE WIRE WHEN GIVEN AND VANISH WHEN NOT.
    /// `sourceType` defaults to `"text"` server-side, so sending it explicitly is
    /// what makes the stored row match what the form showed.
    ///
    /// ⚠️ THE SLASHES ARE NORMALISED BEFORE COMPARING. `JSONEncoder` escapes `/` as
    /// `\/` on Linux and not on Darwin, and both are valid JSON that decodes
    /// identically, so a byte-exact assertion on a body containing a URL would pass
    /// on the CI runner and fail the day it runs on a Mac. `EndpointTableTests`
    /// carries the same helper for the same reason.
    func testAnImportedDocumentCarriesItsSourceTypeAndUrl() async {
        let transport = RepositoryTransport(json: KnowledgeBodies.created)

        _ = await repository(transport).addDocument(
            workspaceId: "ws_1",
            title: "Service area",
            content: "We cover the GTA.",
            sourceType: "url",
            sourceUrl: "https://example.test/service-area"
        )

        XCTAssertEqual(
            transport.bodies.first.map(Self.unescapeSlashes),
            #"{"content":"We cover the GTA.","sourceType":"url","#
                + #""sourceUrl":"https://example.test/service-area","#
                + #""title":"Service area","workspaceId":"ws_1"}"#
        )
    }

    /// ⛔ `success: true` WITH NO `document` IS DRIFT, NOT AN EMPTY SUCCESS. The
    /// route always echoes the row it created, so nil means the contract moved;
    /// answering success with nothing in hand would leave a caller to invent a
    /// document that may or may not exist, on a route that has already been billed.
    func testACreateThatAffirmsSuccessWithNoDocumentIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await repository(transport).addDocument(
            workspaceId: "ws_1",
            title: "Holiday hours",
            content: "We are closed."
        )

        XCTAssertEqual(
            result.failureOnly,
            .decoding("KnowledgeCreateResponse affirmed success with no document")
        )
    }

    func testACreateThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false}"#)

        let result = await repository(transport).addDocument(
            workspaceId: "ws_1",
            title: "Holiday hours",
            content: "We are closed."
        )

        XCTAssertEqual(result.failureOnly, .decoding("KnowledgeCreateResponse did not affirm success=true"))
    }

    /// ⛔ A 400 "no usable text" IS NOT A ZERO-CHUNK DOCUMENT, and the difference is
    /// what the operator is told: nothing was stored, so "it saved but is empty"
    /// would be a false statement about their knowledge base. ⚠️ The 429 is the
    /// 20/min-per-workspace ingest cap, which is Redis-backed and FAIL-OPEN and
    /// therefore not a guarantee anything held; a client must still not retry.
    func testAnEmptyDocumentAndTheIngestCapBothPassThroughWithTheirSentences() async {
        let empty = RepositoryTransport(
            json: #"{"success":false,"error":"Document has no usable text"}"#,
            status: 400
        )
        let refused = await repository(empty).addDocument(workspaceId: "ws_1", title: "T", content: " ")
        XCTAssertEqual(refused.failureOnly, .http(status: 400, message: "Document has no usable text"))

        let capped = RepositoryTransport(json: KnowledgeBodies.rateLimited, status: 429)
        let limited = await repository(capped).addDocument(workspaceId: "ws_1", title: "T", content: "x")
        XCTAssertEqual(limited.failureOnly?.httpStatus, 429)
        XCTAssertEqual(limited.failureOnly?.message, KnowledgeBodies.rateLimitSentence)

        let expired = RepositoryTransport(json: #"{"error":"Unauthorized"}"#, status: 401)
        let unauthorized = await repository(expired).addDocument(workspaceId: "ws_1", title: "T", content: "x")
        XCTAssertEqual(unauthorized.failureOnly?.isUnauthorized, true)

        let degraded = RepositoryTransport(json: #"{"success":false,"error":"Try again"}"#, status: 503)
        let transient = await repository(degraded).addDocument(workspaceId: "ws_1", title: "T", content: "x")
        XCTAssertEqual(transient.failureOnly?.httpStatus, 503)
        XCTAssertNil(transient.successOnly)
    }

    // MARK: - Reading the knowledge source

    func testReadingTheModeGetsTheHyphenatedRouteAndAnswersTheStoredValue() async {
        let transport = RepositoryTransport(json: #"{"success":true,"mode":"linked"}"#)

        let result = await repository(transport).mode(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly, "linked")
        XCTAssertEqual(transport.requests.first?.method, .get)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/knowledge-mode?workspaceId=ws_1"
        )
    }

    /// ⛔ A MODE THIS BUILD DOES NOT KNOW IS CARRIED THROUGH RATHER THAN REJECTED OR
    /// DEFAULTED. Defaulting is the dangerous half: it would report `internal`, i.e.
    /// "your questions stay in region", for a workspace whose questions do not.
    func testAnUnknownModeIsCarriedThroughRatherThanDefaulted() async {
        let transport = RepositoryTransport(json: #"{"success":true,"mode":"federated"}"#)

        let result = await repository(transport).mode(workspaceId: "ws_1")

        XCTAssertEqual(result.successOnly, "federated")
        XCTAssertNil(result.failureOnly)
    }

    func testAModeReadThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false,"mode":"internal"}"#)

        let result = await repository(transport).mode(workspaceId: "ws_1")

        XCTAssertEqual(result.failureOnly, .decoding("KnowledgeModeResponse did not affirm success=true"))
    }

    /// ⚠️ A 400 HERE IS THE MISSING `workspaceId` GUARD, which runs BEFORE the role
    /// check on this route, so it is the one status on this surface that means "the
    /// request was malformed" rather than "you may not".
    func testAMalformedModeReadAndAnOutageKeepTheirStatuses() async {
        let malformed = RepositoryTransport(json: #"{"success":false,"error":"Invalid payload"}"#, status: 400)
        let rejected = await repository(malformed).mode(workspaceId: "ws_1")
        XCTAssertEqual(rejected.failureOnly, .http(status: 400, message: "Invalid payload"))

        let expired = RepositoryTransport(json: #"{"error":"Unauthorized"}"#, status: 401)
        let unauthorized = await repository(expired).mode(workspaceId: "ws_1")
        XCTAssertEqual(unauthorized.failureOnly?.isUnauthorized, true)

        let degraded = RepositoryTransport(json: #"{"success":false,"error":"Try again"}"#, status: 503)
        let transient = await repository(degraded).mode(workspaceId: "ws_1")
        XCTAssertEqual(transient.failureOnly?.httpStatus, 503)
        XCTAssertNil(transient.successOnly)
    }

    // MARK: - Choosing the knowledge source

    /// ⛔ THE ECHO IS ADOPTED, NOT THE VALUE THAT WAS ASKED FOR, AND THIS TEST IS
    /// BUILT SO THE TWO CANNOT AGREE BY ACCIDENT: the request asks for `linked` and
    /// the stub answers `internal`, which is what the server's own sanitiser would
    /// do if it disagreed. A repository that returned its argument would pass a test
    /// where the two matched and report a mode nobody stored in production.
    func testSettingTheModeAdoptsTheServersEchoRatherThanTheRequestedValue() async {
        let transport = RepositoryTransport(json: #"{"success":true,"mode":"internal"}"#)

        let result = await repository(transport).setMode(workspaceId: "ws_1", mode: .linked)

        XCTAssertEqual(result.successOnly, "internal", "⛔ the echo, not the argument")
        XCTAssertEqual(transport.requests.first?.method, .patch)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/workspace/knowledge-mode"
        )
        XCTAssertEqual(transport.bodies.first, #"{"mode":"linked","workspaceId":"ws_1"}"#)
    }

    /// ⚠️ THE WIRE SPELLING OF THE IN-REGION MODE IS `internal`, WHICH IS A SWIFT
    /// KEYWORD ON THIS SIDE. The backticks are a Swift concern only, and this asserts
    /// that none of them reaches the request.
    func testTheInRegionModeGoesOnTheWireAsItsPlainSpelling() async {
        let transport = RepositoryTransport(json: #"{"success":true,"mode":"internal"}"#)

        _ = await repository(transport).setMode(workspaceId: "ws_1", mode: .internal)

        XCTAssertEqual(transport.bodies.first, #"{"mode":"internal","workspaceId":"ws_1"}"#)
    }

    func testAModeWriteThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false,"mode":"linked"}"#)

        let result = await repository(transport).setMode(workspaceId: "ws_1", mode: .linked)

        XCTAssertEqual(result.failureOnly, .decoding("KnowledgeModeResponse did not affirm success=true"))
    }

    /// ⛔ THE WRITE EXCLUDES `viewer` WHILE THE READ ADMITS ONE, so a 403 here is the
    /// role gate and is expected rather than exceptional: a read-only member can see
    /// the mode and may not change where answers come from.
    func testAViewersModeWriteAndAnOutageBothPassThrough() async {
        let viewer = RepositoryTransport(json: #"{"success":false,"error":"Forbidden"}"#, status: 403)
        let refused = await repository(viewer).setMode(workspaceId: "ws_1", mode: .linked)
        XCTAssertEqual(refused.failureOnly, .http(status: 403, message: "Forbidden"))
        XCTAssertEqual(refused.failureOnly?.isUnauthorized, false, "403 is not a token problem")

        let expired = RepositoryTransport(json: #"{"error":"Unauthorized"}"#, status: 401)
        let unauthorized = await repository(expired).setMode(workspaceId: "ws_1", mode: .linked)
        XCTAssertEqual(unauthorized.failureOnly?.isUnauthorized, true)

        let degraded = RepositoryTransport(
            json: #"{"success":false,"error":"Could not save the knowledge source."}"#,
            status: 503
        )
        let transient = await repository(degraded).setMode(workspaceId: "ws_1", mode: .linked)
        XCTAssertEqual(transient.failureOnly?.httpStatus, 503)
        XCTAssertNil(transient.successOnly)
    }

    /// See the ⚠️ on ``testAnImportedDocumentCarriesItsSourceTypeAndUrl()``.
    private static func unescapeSlashes(_ text: String) -> String {
        text.replacingOccurrences(of: "\\/", with: "/")
    }
}

/// Minimal, VALID bodies for the knowledge shapes.
///
/// ⚠️ NOT THE CONTRACT FIXTURES. `district-knowledge*.json` pins the wire shape
/// through the strict gate; what lives here is the smallest body that satisfies the
/// Swift type, so these tests can be about outcomes, paths and request bytes rather
/// than about JSON.
private enum KnowledgeBodies {
    /// - Parameter sourced: false produces the PASTED document, whose `sourceUrl` is
    ///   an explicit null rather than a URL.
    static func list(ids: [String], sourced: Bool = true) -> String {
        let rows = ids.map { document(id: $0, sourced: sourced) }.joined(separator: ",")
        return #"{"success":true,"documents":[\#(rows)]}"#
    }

    static func document(id: String, sourced: Bool) -> String {
        let type = sourced ? "url" : "text"
        let source = sourced ? #""https://example.test/page""# : "null"
        return #"""
        {"id":"\#(id)","title":"Refund policy","sourceType":"\#(type)","sourceUrl":\#(source),
         "status":"ready","chunkCount":4,"createdAt":"2026-08-15T14:30:00.000Z"}
        """#
    }

    /// ⚠️ SIX KEYS, NOT SEVEN. The create route's `select` omits `sourceUrl`, and a
    /// body that carried it would be testing a shape the server does not send.
    static let created = #"""
    {"success":true,"document":{"id":"doc_new","title":"Holiday hours","sourceType":"text",
     "status":"ready","chunkCount":2,"createdAt":"2026-08-15T14:30:00.000Z"}}
    """#

    /// ⛔ BUILT BY CONCATENATION RATHER THAN WRAPPED INSIDE THE JSON. A raw
    /// multi-line string may break between JSON tokens, but a newline INSIDE a string
    /// value is invalid JSON, and the failure it produces reads as a bug in the
    /// repository under test rather than in the fixture.
    static let rateLimited = #"{"error":"\#(rateLimitSentence)"}"#

    static let rateLimitSentence = "Too many knowledge uploads for this workspace. "
        + "Please try again shortly."
}
