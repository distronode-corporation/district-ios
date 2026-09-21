import ContractGateSupport
import DistrictModel
import Foundation
import XCTest

/// Per-fixture assertions for the CRM surface, and the one decision ``Contact``
/// makes on top of the raw row it carries.
///
/// ⚠️ THE STRICT GATE PROVES THE KEY SET; THESE PROVE THE BRANCHES. See
/// `AuthWorkspaceContractTests` for the full statement of why both exist. A
/// computed property is invisible to the gate by construction — the gate
/// decodes, re-encodes and compares keys, and never asks the DTO a question — so
/// nothing but a test like this covers ``Contact/displayName`` at all.
final class ContactsContractTests: XCTestCase {
    // MARK: - The two rows the list fixture exists to cover

    /// ⛔ ROW 1 IS THE EMAIL-FIRST CONTACT AND IT IS THE POINT OF THE FIXTURE.
    /// Contacts do not require a phone; the unique index
    /// tolerates any number of phone-less rows because Postgres treats NULLs as
    /// distinct. A regeneration that produced two fully-populated rows would
    /// still pass the strict gate and would stop covering this.
    ///
    /// ⛔ AND `dgiStatus: null` IS NOT `pending`. `contacts/clear-intel` resets
    /// the column to NULL so nothing re-crawls the contact, so null means "no
    /// dossier, and none queued" — the state that should offer enrichment rather
    /// than spin on a job that will never complete.
    func testTheListCoversAnEnrichedRowAndAnEmailFirstOne() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-contacts.json",
            as: ContactListResponse.self
        )
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.contacts.count, 2)
        XCTAssertEqual(response.total, response.contacts.count)
        // ⚠️ THE LIMIT THE SERVER APPLIED, not the one that was asked for: it
        // clamps anything above 100, non-numeric or non-positive. Page
        // arithmetic uses these two.
        XCTAssertEqual(response.limit, 100)
        XCTAssertEqual(response.offset, 0)

        let enriched = response.contacts[0]
        XCTAssertEqual(enriched.displayName, "Contract Test Caller")
        XCTAssertEqual(enriched.dgiStatus, DgiStatus.complete)
        XCTAssertNil(enriched.dgiError, "the column is null on every contact whose enrichment never failed")
        XCTAssertNotNil(enriched.phoneNumber)

        let emailFirst = response.contacts[1]
        XCTAssertNil(emailFirst.phoneNumber, "a phone-less contact is required to decode, not merely tolerated")
        XCTAssertNotNil(emailFirst.email)
        XCTAssertEqual(emailFirst.displayName, "Sparse Contact")
        XCTAssertNil(emailFirst.dgiStatus)
        XCTAssertFalse(
            DgiStatus.isInProgress(emailFirst.dgiStatus),
            "no dossier and none queued must not read as work in flight"
        )
    }

    /// ⛔ ONE DTO SERVES BOTH ROUTES BECAUSE BOTH RETURN THE RAW PRISMA ROW, AND
    /// THIS IS THE ASSERTION THAT SAYS SO. The alternative the server could have
    /// taken — reusing `getPaginatedContacts` for the list — returns a MAPPED
    /// shape that silently drops `dgiStatus`, `dgiError` and `visualMemory`. The
    /// detail screen needs `dgiStatus`, so that choice would have forced two
    /// contact shapes with different nullability onto this client. Comparing the
    /// two encodings is what would catch the list route drifting onto the mapper.
    func testTheDetailRouteReturnsTheSameRowAsTheList() throws {
        let list = try StrictDecodeVerifier.verify(
            fixture: "district-contacts.json",
            as: ContactListResponse.self
        )
        let detail = try StrictDecodeVerifier.verify(
            fixture: "district-contact-detail.json",
            as: ContactDetailResponse.self
        )
        XCTAssertTrue(detail.success)
        let single = try XCTUnwrap(detail.contact, "nil is a malformed response; a missing contact is a 404")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(
            try encoder.encode(single),
            try encoder.encode(list.contacts[0]),
            "the two routes must serve one row through one type"
        )
        // The three columns the mapped shape would have dropped, named so a
        // regression points at the cause rather than at a diff.
        XCTAssertEqual(single.dgiStatus, DgiStatus.complete)
        XCTAssertNotNil(single.visualMemory)
    }

    // MARK: - Name resolution

    /// ⛔ THE "Unknown" LITERAL IS THE WHOLE REASON THIS HELPER EXISTS. `name` is
    /// non-null server-side, so a blank check alone leaves a contact list full of
    /// rows all called Unknown — the voice agent writes that exact string for a
    /// caller it could not identify. nil means "fall back to the number or the
    /// address", which is a decision the caller has to be given the chance to
    /// make.
    func testTheUnknownLiteralIsNotADisplayableName() throws {
        XCTAssertEqual(ContactNames.unknown, "Unknown", "the literal the voice agent writes")
        XCTAssertNil(try contact(named: "Unknown").displayName)
        XCTAssertNil(try contact(named: "").displayName)
        XCTAssertNil(try contact(named: "   ").displayName, "whitespace is not a label either")
    }

    /// ⚠️ ONE LITERAL, NOT A HEURISTIC. Suppressing anything that merely looked
    /// unidentified would hide real names — people are called Unknown Ltd and
    /// unknown@ is a real mailbox — so the comparison is exact and
    /// case-sensitive, matching the one string the agent actually stores.
    func testOnlyTheExactLiteralIsSuppressed() throws {
        XCTAssertEqual(try contact(named: "Unknown Caller").displayName, "Unknown Caller")
        XCTAssertEqual(try contact(named: "unknown").displayName, "unknown", "case-sensitive on purpose")
        XCTAssertEqual(try contact(named: "Unknown Industries Ltd").displayName, "Unknown Industries Ltd")
    }

    /// ⚠️ THE TRIM IS A PROBE, NOT A REWRITE. A name that survives comes back
    /// exactly as the server stored it, padding included; this client invents no
    /// canonical form for a column a human types into.
    ///
    /// ⛔ DIVERGENCE FROM THE KOTLIN CLIENT, DELIBERATE AND STRICTER. Kotlin's
    /// `Contact.displayName` is
    /// `name.takeUnless { it.isBlank() || it == UNKNOWN_NAME }`, which compares
    /// the RAW value — so a padded `"  Unknown  "` is displayable on Android and
    /// suppressed here. iOS trims before comparing because padding changes
    /// nothing about how useless that literal is as a label, and a row written
    /// with stray whitespace is exactly the row a raw comparison misses. Every
    /// other input agrees between the two clients.
    func testDisplayNameHandsBackTheStoredNameVerbatim() throws {
        XCTAssertEqual(try contact(named: "  Ada  ").displayName, "  Ada  ")
        XCTAssertNil(try contact(named: "  Unknown  ").displayName)
    }

    // MARK: - The columns nothing validates

    /// ⚠️ CARRIED, NEVER REWRITTEN, AND READ DEFENSIVELY AT THE POINT OF DISPLAY.
    /// All three of these are `Json?` columns with no server-side shape, so the
    /// documented form is a convention rather than a guarantee — reading one the
    /// wrong way has to answer "nothing to show" instead of throwing.
    func testTheOpaqueColumnsAreCarriedAndReadDefensively() throws {
        let response = try StrictDecodeVerifier.verify(
            fixture: "district-contacts.json",
            as: ContactListResponse.self
        )
        let enriched = response.contacts[0]
        XCTAssertEqual(enriched.socialHandles?["linkedin"]?.stringValue, "ada-l")
        XCTAssertEqual(enriched.intelligence?["summary"]?.stringValue, "Interested in Thursday.")
        XCTAssertEqual(enriched.visualMemory?.arrayValue?.count, 1)
        // ⚠️ The schema comment says "array of strings" and nothing enforces it,
        // so the wrong read is nil rather than a crash on a phone.
        XCTAssertNil(enriched.visualMemory?.objectValue)
        XCTAssertNil(enriched.socialHandles?.arrayValue)

        // The sparse row leaves every one of them unset, which is the ordinary
        // state of a contact nobody has enriched.
        let emailFirst = response.contacts[1]
        XCTAssertNil(emailFirst.socialHandles)
        XCTAssertNil(emailFirst.intelligence)
        XCTAssertNil(emailFirst.visualMemory)
        XCTAssertNil(emailFirst.company)
    }

    /// ⚠️ EVERY FIELD OF ``ContactCompany`` IS OPTIONAL BECAUSE A ROW WRITTEN BY
    /// AN EARLIER PIPELINE MAY CARRY FEWER KEYS. The strict gate covers drift in
    /// the other direction — a NEW key — while the shipped parser stays lenient,
    /// so this is the half the gate cannot see.
    func testCompanyDecodesARowAnEarlierPipelineWroteFewerKeysOn() throws {
        let partial = try decode(ContactCompany.self, from: #"{"name":"Analytical Engines"}"#)
        XCTAssertEqual(partial.name, "Analytical Engines")
        XCTAssertNil(partial.domain)
        XCTAssertNil(partial.industry)

        let empty = try decode(ContactCompany.self, from: "{}")
        XCTAssertNil(empty.name, "an empty blob is a shape this column permits")
    }
}

// MARK: - Helpers

/// A contact carrying nothing but the four non-null columns, so a test about
/// ``Contact/displayName`` reads as one about names.
///
/// ⚠️ BUILT FROM THE WIRE SHAPE RATHER THAN A MEMBERWISE INITIALISER, so the
/// branches below are reached the same way production reaches them: through
/// `Codable`. Every other column is Optional and absent here, which is itself
/// the shape a freshly created contact arrives in.
private func contact(named name: String) throws -> Contact {
    try decode(
        Contact.self,
        from: #"""
        {"id":"contact_contract_1","workspaceId":"ws-contract-test",
         "name":"\#(name)","createdAt":"2026-08-15T14:30:00.000Z"}
        """#
    )
}
