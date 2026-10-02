import ContractGateSupport
import DistrictModel
import Foundation
import XCTest

/// Per-fixture assertions for the knowledge base: the document list, the create
/// echo, and the two bodies of the mode route.
///
/// ⛔ THE STRICT GATE CANNOT SEE THE ONE FACT THAT MATTERS MOST HERE. `GET` and
/// `POST` on `workspace/knowledge` answer DIFFERENT key sets from the same table
/// (`sourceUrl` is in the list's `select` and not in the create's), and the gate
/// compares each fixture against the DTO rather than against its sibling, so
/// nothing in it would notice a DTO that required the field and threw on every
/// successful upload. That pairing is asserted below.
///
/// ⚠️ AND THE MODE FIXTURES ARE VALUE-LEVEL BY NATURE. Both bodies have the same
/// two keys and differ only in which mode they carry, which is the whole point of
/// having two: `linked` means this workspace's questions leave its region for
/// Atlassian, and a client that read the two the same way would report the safe
/// answer for a workspace that chose the other one.
final class KnowledgeContractTests: XCTestCase {
    // MARK: - The document list

    /// ⛔ TWO ROWS THAT COVER THE FIELD UNION AND BOTH SOURCE KINDS. Row 0 is a
    /// pasted document: `sourceType: "text"`, `sourceUrl` an explicit null, four
    /// chunks and `status: "ready"`. Row 1 is imported from a page: a real
    /// `sourceUrl`, ZERO chunks and `status: "processing"`, which is the state that
    /// proves a document can exist with nothing embedded behind it yet. A screen
    /// that read `chunkCount: 0` as an empty document rather than an unfinished
    /// one would be wrong about a row the customer just uploaded.
    func testTheDocumentListCoversBothSourceKindsAndTheUnfinishedRow() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-knowledge.json",
            as: KnowledgeListResponse.self
        )

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.documents.map(\.id), ["doc_contract_ready", "doc_contract_processing"])

        let pasted = try XCTUnwrap(response.documents.first)
        XCTAssertEqual(pasted.title, "Refund policy")
        XCTAssertEqual(pasted.sourceType, "text")
        XCTAssertNil(pasted.sourceUrl, "a pasted document has no source, and the key is SENT as null")
        XCTAssertEqual(pasted.status, "ready")
        XCTAssertEqual(pasted.chunkCount, 4)
        XCTAssertEqual(pasted.createdAt, "2026-08-15T14:30:00.000Z")

        let imported = try XCTUnwrap(response.documents.last)
        XCTAssertEqual(imported.sourceType, "url")
        XCTAssertEqual(imported.sourceUrl, "https://contract.test/service-area")
        XCTAssertEqual(imported.status, "processing")
        XCTAssertEqual(imported.chunkCount, 0, "⚠️ not embedded YET, which is not the same as empty")
    }

    // MARK: - The create echo

    /// ⛔ THE CREATE RESPONSE IS ONE FIELD SHORT OF A LIST ROW, AND THIS IS THE
    /// TEST THAT SAYS SO. The route's `select` omits `sourceUrl`, so the key is
    /// ABSENT rather than null: a DTO that required it would throw on the response
    /// to a successful, already-billed upload, and a list rebuilt by appending this
    /// row would show a document with no source until the next full read.
    func testTheCreateEchoOmitsTheSourceUrlRatherThanNullingIt() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-knowledge-create.json",
            as: KnowledgeCreateResponse.self
        )

        XCTAssertTrue(response.success)
        let document = try XCTUnwrap(response.document, "the route always echoes the row it made")
        XCTAssertEqual(document.id, "doc_contract_created")
        XCTAssertEqual(document.title, "Holiday hours")
        XCTAssertEqual(document.sourceType, "text")
        XCTAssertEqual(document.status, "ready")
        XCTAssertEqual(document.chunkCount, 2, "⚠️ what the upload cost, in embeddings")
        XCTAssertNil(document.sourceUrl)
    }

    /// ⛔ THE ASYMMETRY ASSERTED ON THE RAW BYTES, because it is a fact about the
    /// two routes rather than about the Swift type, and the gate compares each
    /// fixture only against the DTO. ⚠️ ABSENT AND NULL BOTH DECODE TO nil, so
    /// without this the difference between the two fixtures would be invisible to
    /// every assertion above.
    func testOnlyTheListRouteSelectsTheSourceUrlAtAll() throws {
        let listRow = try Self.firstDocument(in: "district-knowledge.json", under: "documents")
        let createdRow = try Self.document(in: "district-knowledge-create.json", under: "document")

        XCTAssertTrue(listRow.keys.contains("sourceUrl"), "GET selects it, and nulls it on a pasted row")
        XCTAssertFalse(createdRow.keys.contains("sourceUrl"), "⛔ POST does not select it at all")
        XCTAssertEqual(
            Set(listRow.keys).subtracting(createdRow.keys),
            ["sourceUrl"],
            "the two selects differ in exactly one field, and this is it"
        )
    }

    // MARK: - The knowledge source

    /// ⛔ TWO FIXTURES FOR ONE SHAPE BECAUSE THE VALUE IS THE PRODUCT. `linked`
    /// sends this workspace's questions to Atlassian to be answered, which is a
    /// data-residency change; `internal` keeps retrieval in the workspace's own
    /// region. The key set is identical, so only a value-level assertion can tell
    /// the two apart, and a client that conflated them would report the safe answer
    /// for a workspace that chose the other one.
    ///
    /// ⚠️ THE READ CARRIES `linked` AND THE PATCH CARRIES `internal`, i.e. the
    /// fixtures are not two copies of one state: between them they prove both
    /// members of the vocabulary decode, on both verbs.
    func testTheModeReadAndItsPatchCarryOppositeStatesOfTheSameShape() throws {
        let read = try StrictDecodeVerifier.verify(
            fixture: "district-knowledge-mode.json",
            as: KnowledgeModeResponse.self
        )
        XCTAssertTrue(read.success)
        XCTAssertEqual(read.mode, "linked")
        XCTAssertEqual(KnowledgeMode(rawValue: read.mode), .linked, "⛔ questions leave the region in this state")

        let patched = try StrictDecodeVerifier.verify(
            fixture: "district-knowledge-mode-patch.json",
            as: KnowledgeModeResponse.self
        )
        XCTAssertTrue(patched.success)
        XCTAssertEqual(patched.mode, "internal")
        XCTAssertEqual(KnowledgeMode(rawValue: patched.mode), .internal)
    }

    /// ⚠️ `mode` IS A TOP-LEVEL KEY, ASSERTED ON THE BYTES. The route spreads the
    /// stored config into the envelope (`{success:true, ...config}`), and a DTO
    /// shaped `{success, config:{mode}}` would decode to no mode at all and read as
    /// `internal` for a workspace that chose `linked`. That is the wrong answer in
    /// the dangerous direction, so the flat shape is pinned rather than assumed.
    func testTheModeIsSpreadIntoTheEnvelopeRatherThanNested() throws {
        for name in ["district-knowledge-mode.json", "district-knowledge-mode-patch.json"] {
            let raw = try ContractFixtures.read(name)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any], name)
            XCTAssertEqual(Set(object.keys), ["success", "mode"], "\(name) is not the flat shape")
        }
    }

    /// ⛔ AN UNKNOWN MODE DECODES AND REPORTS nil RATHER THAN THROWING, WHICH IS
    /// THE OPPOSITE DECISION FROM ``SchedulingTenantStatus`` AND THE DIFFERENCE IS
    /// THE SERVER-SIDE CONSTRAINT, NOT TASTE. The tenancy status is CHECK-constrained
    /// in SQL; `knowledgeConfig.mode` is a `Json?` column whose read path repairs an
    /// unrecognised value to the default, so a THIRD mode added server-side must
    /// arrive as a value to display instead of failing a settings read on a build
    /// that has not learned it. ⚠️ No fixture carries one, so this is decoded from
    /// literal bytes.
    func testAModeOutsideTheVocabularyStillDecodesAndReportsNoKnownMode() throws {
        let data = Data(#"{"success":true,"mode":"federated"}"#.utf8)
        let response = try JSONDecoder().decode(KnowledgeModeResponse.self, from: data)

        XCTAssertEqual(response.mode, "federated")
        XCTAssertNil(KnowledgeMode(rawValue: response.mode), "not a mode this build knows, which is not an error")
    }

    /// The two wire spellings, pinned as strings and in the server's own order.
    /// ⚠️ Asserted rather than derived from `rawValue`, which would assert that the
    /// enum equals itself. ⛔ `internal` comes first because it is the server's
    /// default, and the default is the in-region one on purpose.
    func testTheModeVocabularyIsTheTwoServerValues() {
        XCTAssertEqual(KnowledgeMode.allCases.map(\.rawValue), ["internal", "linked"])
    }

    // MARK: - Helpers

    private static func document(in fixture: String, under key: String) throws -> [String: Any] {
        let raw = try ContractFixtures.read(fixture)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any], fixture)
        return try XCTUnwrap(envelope[key] as? [String: Any], "\(fixture) has no object at \(key)")
    }

    private static func firstDocument(in fixture: String, under key: String) throws -> [String: Any] {
        let raw = try ContractFixtures.read(fixture)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any], fixture)
        let rows = try XCTUnwrap(envelope[key] as? [[String: Any]], "\(fixture) has no array at \(key)")
        return try XCTUnwrap(rows.first, "\(fixture) has an empty \(key)")
    }
}
