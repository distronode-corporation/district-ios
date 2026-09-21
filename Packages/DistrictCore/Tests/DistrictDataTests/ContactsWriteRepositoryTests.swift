@testable import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The five contact MUTATIONS: create, rename, delete, enrich and clear-intel.
///
/// ⚠️ A SEPARATE FILE FROM `RepositoryTests`, WHICH HOLDS THE CONTACT READS, for
/// the reason that file's own header gives about the inbox: SwiftLint's ceilings
/// are 500 lines per file and 400 per type, and the writes are thirteen cases with
/// their reasoning attached. The split is by SURFACE, not by kind — the pager and
/// the detail read stay next door.
///
/// ⛔ THREE OF THESE ROUTES ARE NOT ORDINARY WRITES. `enrich` spends money and is
/// not idempotent, `clear-intel` destroys data that costs money to rebuild, and
/// `delete` removes a customer record — so the assertions below are about what
/// this client SENDS and what it folds into success, not only about decoding.
final class ContactsWriteRepositoryTests: XCTestCase {
    func testCreatingAContactPostsToCreateAndAnswersTheNewId() async {
        let transport = RepositoryTransport(json: #"{"success":true,"id":"c_9"}"#)

        let result = await ContactsRepository(client: .repositoryTest(transport))
            .create(workspaceId: "ws_1", name: "Ada Lovelace", phoneNumber: "+14165550134", email: nil)

        XCTAssertEqual(result.successOnly, "c_9")
        XCTAssertEqual(transport.requests.first?.method, .post)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/contacts/create"
        )
    }

    /// ⛔ A BLANK FIELD BECOMES AN ABSENT KEY, NOT `""`. The route reads
    /// `typeof phoneNumber === "string" && phoneNumber.trim()` for the phone and
    /// `normalizeAddress` for the email, so the two disagree about what an empty
    /// string means; normalising to absent once is what keeps the client's own
    /// validation and the server's asking the same question.
    func testCreatingAContactDropsBlankFieldsRatherThanSendingEmptyStrings() async {
        let transport = RepositoryTransport(json: #"{"success":true,"id":"c_9"}"#)

        _ = await ContactsRepository(client: .repositoryTest(transport))
            .create(workspaceId: "ws_1", name: "Ada Lovelace", phoneNumber: "  ", email: " ada@example.com ")

        XCTAssertEqual(
            transport.bodies.first,
            #"{"email":"ada@example.com","name":"Ada Lovelace","workspaceId":"ws_1"}"#
        )
    }

    func testACreateThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false,"id":"c_9"}"#)

        let result = await ContactsRepository(client: .repositoryTest(transport))
            .create(workspaceId: "ws_1", name: "Ada", phoneNumber: "+14165550134", email: nil)

        XCTAssertEqual(result.failureOnly, .decoding("ContactCreateResponse did not affirm success=true"))
    }

    /// ⚠️ A 409 IS A DUPLICATE, AND THE ROUTE'S OWN SENTENCE NAMES WHICH KEY
    /// COLLIDED. It has to reach the screen intact; a generic "could not save"
    /// would hide the only actionable half of the answer.
    func testACreateConflictKeepsTheRoutesOwnSentence() async {
        let transport = RepositoryTransport(
            json: #"{"success":false,"error":"A contact with this email address already exists in this workspace."}"#,
            status: 409
        )

        let result = await ContactsRepository(client: .repositoryTest(transport))
            .create(workspaceId: "ws_1", name: "Ada", phoneNumber: nil, email: "ada@example.com")

        XCTAssertEqual(
            result.failureOnly,
            .http(status: 409, message: "A contact with this email address already exists in this workspace.")
        )
    }

    /// ⛔ THE RENAME RE-SENDS EVERY COLUMN THE ROUTE REWRITES, AND THIS TEST IS
    /// THE GUARD ON THAT. `contacts/update` hands Prisma one unconditional `data`
    /// block, so a body that omits a field REPLACES it: both addresses rebuilt
    /// from the body (absent means null, and both null is a 400 with "A contact
    /// needs a phone number or an email address"), `socialHandles` overwritten
    /// with `{linkedin: linkedin || ""}`, `latestContextSummary` with
    /// `contextSummary || "Manual edit update."`, and budget, timeline and
    /// website each with `|| ""`.
    ///
    /// 🔑 The byte-exact body is the only assertion that can catch a DROPPED key:
    /// ``JSONValue/object(_:)`` removes a nil pair silently by design, so an
    /// argument that never reached the wire looks identical to one that did until
    /// the document itself is compared. A four-key body would read as correct
    /// while every rename cleared four columns.
    func testRenamingPatchesUpdateAndResendsEveryColumnTheRouteRewrites() async throws {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let contact = try Self.contact(Self.fullContactJSON)

        let result = await ContactsRepository(client: .repositoryTest(transport)).rename(
            workspaceId: "ws_1",
            contact: contact,
            name: "Ada Lovelace"
        )

        XCTAssertNil(result.failureOnly)
        XCTAssertEqual(transport.requests.first?.method, .patch)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/contacts/update"
        )
        XCTAssertEqual(
            transport.bodies.first,
            #"{"budget":"5k-10k","contactId":"c_1","contextSummary":"Asked about a survey.","#
                + #""email":"ada@example.com","linkedin":"in-ada","name":"Ada Lovelace","#
                + #""phoneNumber":"+14165550134","timeline":"Q4","website":"example.com","#
                + #""workspaceId":"ws_1"}"#
        )
    }

    /// ⛔ A COLUMN THE CONTACT DOES NOT HAVE IS AN ABSENT KEY, NOT `""`. Both
    /// reach the same stored value here (the handler's `|| ""` absorbs either),
    /// so the choice is about not inventing a value the contact never held, and
    /// about keeping one rule across the four routes where an explicit blank and
    /// an absent key are genuinely different instructions.
    ///
    /// ⚠️ WHAT THIS CANNOT PROMISE IS THAT THE COLUMNS STAY NULL. The route
    /// writes `""` for an absent budget, timeline or website and "Manual edit
    /// update." for an absent summary whatever this client sends; there is no
    /// body that preserves a SQL NULL, and pretending otherwise here would be a
    /// test agreeing with a wish.
    func testRenamingAContactWithNoOptionalColumnsOmitsTheirKeys() async throws {
        let transport = RepositoryTransport(json: #"{"success":true}"#)
        let bare = #"""
        {"id":"c_1","workspaceId":"ws_1","name":"Ada","phoneNumber":"+14165550134",
         "email":"ada@example.com","createdAt":"2026-08-19T09:41:00.000Z"}
        """#

        let contact = try Self.contact(bare)

        _ = await ContactsRepository(client: .repositoryTest(transport)).rename(
            workspaceId: "ws_1",
            contact: contact,
            name: "Ada Lovelace"
        )

        XCTAssertEqual(
            transport.bodies.first,
            #"{"contactId":"c_1","email":"ada@example.com","name":"Ada Lovelace","#
                + #""phoneNumber":"+14165550134","workspaceId":"ws_1"}"#
        )
    }

    /// ⚠️ A PHONE-LESS CONTACT DROPS THE PHONE KEY AND KEEPS EVERYTHING ELSE.
    /// The key is dropped rather than sent as null, which is the same thing to
    /// this route and the right thing on every other one, and the columns that
    /// ARE present still have to ride along, which is what the budget here pins.
    func testRenamingAPhonelessContactDropsThePhoneAndKeepsTheRest() async throws {
        let transport = RepositoryTransport(json: #"{"success":true}"#)
        let phoneless = #"""
        {"id":"c_1","workspaceId":"ws_1","name":"Ada","email":"ada@example.com",
         "budget":"5k-10k","createdAt":"2026-08-19T09:41:00.000Z"}
        """#

        let contact = try Self.contact(phoneless)

        _ = await ContactsRepository(client: .repositoryTest(transport)).rename(
            workspaceId: "ws_1",
            contact: contact,
            name: "Ada Lovelace"
        )

        XCTAssertEqual(
            transport.bodies.first,
            #"{"budget":"5k-10k","contactId":"c_1","email":"ada@example.com","#
                + #""name":"Ada Lovelace","workspaceId":"ws_1"}"#
        )
    }

    /// ⛔ `socialHandles` IS A `Json?` COLUMN WITH NO SERVER-SIDE SHAPE, so an
    /// ARRAY is a value it can genuinely hold. Reading it must answer "no
    /// handle", not trap: ``WireJSON``'s subscript returns nil for anything that
    /// is not an object.
    func testASocialHandlesBlobThatIsNotAnObjectYieldsNoLinkedinKey() async throws {
        let transport = RepositoryTransport(json: #"{"success":true}"#)
        let odd = #"""
        {"id":"c_1","workspaceId":"ws_1","name":"Ada","email":"ada@example.com",
         "socialHandles":["linkedin"],"createdAt":"2026-08-19T09:41:00.000Z"}
        """#

        let contact = try Self.contact(odd)

        _ = await ContactsRepository(client: .repositoryTest(transport)).rename(
            workspaceId: "ws_1",
            contact: contact,
            name: "Ada Lovelace"
        )

        XCTAssertEqual(
            transport.bodies.first,
            #"{"contactId":"c_1","email":"ada@example.com","name":"Ada Lovelace","workspaceId":"ws_1"}"#
        )
    }

    /// ⛔ AND THE KEY MAY BE PRESENT WITH THE WRONG TYPE. `linkedin: 42` is not a
    /// handle; forwarding `"42"` would write a junk value into a column nothing
    /// validates, so ``WireJSON/stringValue`` answering nil is what keeps it out.
    func testANonStringLinkedinValueYieldsNoLinkedinKey() async throws {
        let transport = RepositoryTransport(json: #"{"success":true}"#)
        let odd = #"""
        {"id":"c_1","workspaceId":"ws_1","name":"Ada","email":"ada@example.com",
         "socialHandles":{"linkedin":42},"createdAt":"2026-08-19T09:41:00.000Z"}
        """#

        let contact = try Self.contact(odd)

        _ = await ContactsRepository(client: .repositoryTest(transport)).rename(
            workspaceId: "ws_1",
            contact: contact,
            name: "Ada Lovelace"
        )

        XCTAssertEqual(
            transport.bodies.first,
            #"{"contactId":"c_1","email":"ada@example.com","name":"Ada Lovelace","workspaceId":"ws_1"}"#
        )
    }

    func testARenameThatDoesNotAffirmSuccessIsADecodeFailure() async throws {
        let transport = RepositoryTransport(json: #"{"success":false}"#)

        let contact = try Self.contact(Self.fullContactJSON)

        let result = await ContactsRepository(client: .repositoryTest(transport))
            .rename(workspaceId: "ws_1", contact: contact, name: "Ada")

        XCTAssertEqual(result.failureOnly, .decoding("ContactUpdateResponse did not affirm success=true"))
    }

    func testDeletingAContactUsesTheQueryParameterRoute() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await ContactsRepository(client: .repositoryTest(transport))
            .delete(workspaceId: "ws_1", contactId: "c_1")

        XCTAssertNil(result.failureOnly)
        XCTAssertEqual(transport.requests.first?.method, .delete)
        XCTAssertNil(transport.requests.first?.body)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/contacts/delete?workspaceId=ws_1&contactId=c_1"
        )
    }

    /// ⛔ ALREADY GONE IS THE OUTCOME THE CALLER ASKED FOR. The route answers 404
    /// when its `deleteMany` matched nothing, and reporting that as a failure
    /// shows an error beside a row that really has disappeared.
    func testDeletingAContactThatIsAlreadyGoneCountsAsSuccess() async {
        let transport = RepositoryTransport(
            json: #"{"success":false,"error":"Contact c_1 not found."}"#,
            status: 404
        )

        let result = await ContactsRepository(client: .repositoryTest(transport))
            .delete(workspaceId: "ws_1", contactId: "c_1")

        XCTAssertNil(result.failureOnly)
    }

    /// ⚠️ ONLY THE 404. A 403 or a 500 is a real failure and must not be folded
    /// into "deleted", which would tell the operator a customer record is gone
    /// when it is not.
    func testEveryOtherDeleteFailureIsStillAFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false,"error":"nope"}"#, status: 403)

        let result = await ContactsRepository(client: .repositoryTest(transport))
            .delete(workspaceId: "ws_1", contactId: "c_1")

        XCTAssertEqual(result.failureOnly, .http(status: 403, message: "nope"))
    }

    func testADeleteThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false}"#)

        let result = await ContactsRepository(client: .repositoryTest(transport))
            .delete(workspaceId: "ws_1", contactId: "c_1")

        XCTAssertEqual(result.failureOnly, .decoding("ContactDeleteResponse did not affirm success=true"))
    }

    /// ⚠️ SCHEDULED, NOT DONE. The 200 says `pending` and the dossier arrives on
    /// the contact row later, so this value is the proof the work was queued
    /// rather than the dossier itself.
    func testEnrichingAContactPostsToEnrichAndReportsPending() async {
        let body = #"{"success":true,"status":"pending","message":"scheduled."}"#
        let transport = RepositoryTransport(json: body)

        let result = await ContactsRepository(client: .repositoryTest(transport))
            .enrich(workspaceId: "ws_1", contactId: "c_1")

        XCTAssertEqual(result.successOnly?.status, DgiStatus.pending)
        XCTAssertEqual(transport.requests.first?.method, .post)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/contacts/enrich"
        )
    }

    /// ⛔ THE 403's SENTENCE IS THE PRODUCT AND IT MUST SURVIVE THIS LAYER
    /// UNTOUCHED. It is usually the WORKSPACE opt-in rather than the caller's
    /// role, and it names the settings page that turns the feature on;
    /// rewriting it as a permission error sends the operator to their own
    /// account looking for a switch that is not there.
    func testAnEnrichRefusalKeepsTheWorkspaceOptInSentenceVerbatim() async {
        let sentence = "Lead enrichment is off for this workspace. "
            + "Turn it on in Settings to enrich contacts with external business data."
        let transport = RepositoryTransport(
            json: #"{"success":false,"error":"\#(sentence)"}"#,
            status: 403
        )

        let result = await ContactsRepository(client: .repositoryTest(transport))
            .enrich(workspaceId: "ws_1", contactId: "c_1")

        XCTAssertEqual(result.failureOnly, .http(status: 403, message: sentence))
    }

    func testAnEnrichThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false,"status":"pending","message":"no"}"#)

        let result = await ContactsRepository(client: .repositoryTest(transport))
            .enrich(workspaceId: "ws_1", contactId: "c_1")

        XCTAssertEqual(result.failureOnly, .decoding("EnrichResponse did not affirm success=true"))
    }

    /// ⚠️ **POST**, EVEN THOUGH IT REMOVES DATA: the route exports POST only, and
    /// it is nulling four columns rather than deleting a resource.
    func testClearingADossierPostsToClearIntel() async {
        let transport = RepositoryTransport(json: #"{"success":true}"#)

        let result = await ContactsRepository(client: .repositoryTest(transport))
            .clearIntel(workspaceId: "ws_1", contactId: "c_1")

        XCTAssertNil(result.failureOnly)
        XCTAssertEqual(transport.requests.first?.method, .post)
        XCTAssertEqual(
            transport.requestedURLs.first,
            "https://www.distronode.com/api/district/contacts/clear-intel"
        )
        XCTAssertEqual(transport.bodies.first, #"{"contactId":"c_1","workspaceId":"ws_1"}"#)
    }

    /// ⚠️ UNLIKE THE DELETE, A 404 IS A FAILURE HERE. "Cleared" for a contact
    /// that could not be found is a claim about data nobody read.
    func testClearingADossierOnAMissingContactIsAFailure() async {
        let transport = RepositoryTransport(
            json: #"{"success":false,"error":"Contact not found"}"#,
            status: 404
        )

        let result = await ContactsRepository(client: .repositoryTest(transport))
            .clearIntel(workspaceId: "ws_1", contactId: "c_1")

        XCTAssertEqual(result.failureOnly, .http(status: 404, message: "Contact not found"))
    }

    func testAClearIntelThatDoesNotAffirmSuccessIsADecodeFailure() async {
        let transport = RepositoryTransport(json: #"{"success":false}"#)

        let result = await ContactsRepository(client: .repositoryTest(transport))
            .clearIntel(workspaceId: "ws_1", contactId: "c_1")

        XCTAssertEqual(result.failureOnly, .decoding("ClearIntelResponse did not affirm success=true"))
    }

    // MARK: - Fixtures

    /// One contact holding a value in EVERY column `contacts/update` rewrites.
    ///
    /// ⚠️ NOT A URL IN `website`, DELIBERATELY. Linux's `JSONEncoder` escapes `/`
    /// as `\/` and Darwin's does not, so a slash anywhere in a value would make
    /// the byte-exact body assertions above pass on Linux and fail on a Mac (or
    /// the reverse). The bare host is enough to pin the key.
    private static let fullContactJSON = #"""
    {"id":"c_1","workspaceId":"ws_1","name":"Ada","phoneNumber":"+14165550134",
     "email":"ada@example.com","socialHandles":{"linkedin":"in-ada"},
     "latestContextSummary":"Asked about a survey.","budget":"5k-10k","timeline":"Q4",
     "website":"example.com","createdAt":"2026-08-19T09:41:00.000Z"}
    """#

    /// A ``Contact`` from a wire body.
    ///
    /// ⚠️ DECODED RATHER THAN CONSTRUCTED. `Contact`'s memberwise initialiser is
    /// internal to `DistrictModel`, so no test in this target can call it, and
    /// decoding is the more honest fixture anyway, since it is how the rename's
    /// argument reaches the caller in production. It also means an optional
    /// column is absent here exactly the way the route leaves it absent.
    private static func contact(_ json: String) throws -> Contact {
        try JSONDecoder().decode(Contact.self, from: Data(json.utf8))
    }
}
