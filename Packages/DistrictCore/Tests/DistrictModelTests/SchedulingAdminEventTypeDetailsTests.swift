import DistrictModel
import Foundation
import XCTest

/// The four rows that hang off an event type, and the one thing each of them can
/// be got wrong about.
final class SchedulingAdminEventTypeDetailsTests: XCTestCase {
    private let decoder = JSONDecoder()

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }

    // MARK: - Hosts

    /// ⚠️ `avatar_url` IS ABSENT, NEVER NULL, on this row. Both polarities are
    /// decoded here so the Optional is proven rather than assumed — and the absent
    /// spelling is what lets this fixture family need no entry in the
    /// explicit-null register for its host list.
    func testAHostDecodesWithAndWithoutAnAvatar() throws {
        let withAvatar = try decode(
            SchedulingHost.self,
            #"""
            {"user_id":"su_1","name":"Contract Member","email":"member@distronode.test",
             "avatar_url":"https://example.test/a.png","role":"required","priority":0,
             "archived":false}
            """#
        )
        XCTAssertEqual(withAvatar.userId, "su_1")
        XCTAssertEqual(withAvatar.avatarUrl, "https://example.test/a.png")
        XCTAssertEqual(withAvatar.role, "required")
        XCTAssertEqual(withAvatar.priority, 0)
        XCTAssertFalse(withAvatar.archived)

        let without = try decode(
            SchedulingHost.self,
            #"""
            {"user_id":"su_2","name":"Rotation Host","email":"rotation@contract.test",
             "role":"rotation","priority":2,"archived":true}
            """#
        )
        XCTAssertNil(without.avatarUrl)
        // ⚠️ ARCHIVED AND STILL ASSIGNED, which is not a contradiction: archiving a
        // scheduler user leaves their host rows so historical bookings keep an
        // owner. A host list is not a list of people who can be booked.
        XCTAssertTrue(without.archived)
    }

    // MARK: - Questions

    /// ⛔ `options` IS NULL ON EVERY NON-`select` QUESTION, and null rather than
    /// `[]` is the wire shape. Both polarities, because a client that defaulted the
    /// null to `[]` would render an empty picker on a free-text question.
    func testAQuestionDecodesBothOptionPolarities() throws {
        let select = try decode(
            SchedulingQuestion.self,
            #"""
            {"id":"q_1","event_type_id":"et_1","label":"Which product?","type":"select",
             "options":["District","Ledger"],"required":true,"position":0}
            """#
        )
        XCTAssertEqual(select.eventTypeId, "et_1")
        XCTAssertEqual(select.options, ["District", "Ledger"])
        XCTAssertTrue(select.required)
        XCTAssertEqual(select.position, 0)

        let text = try decode(
            SchedulingQuestion.self,
            #"""
            {"id":"q_2","event_type_id":"et_1","label":"Anything to read first?",
             "type":"text","options":null,"required":false,"position":1}
            """#
        )
        XCTAssertNil(text.options)
        XCTAssertFalse(text.required)
    }

    /// ⛔ `event_type_id` IS NON-NULL HERE AND NULLABLE ON A RULE. The two keys are
    /// spelled the same and mean different things; a question with a null would be
    /// a contract break, not a "global question".
    func testAQuestionWithANullEventTypeIsRefused() {
        XCTAssertThrowsError(
            try decode(
                SchedulingQuestion.self,
                #"""
                {"id":"q_3","event_type_id":null,"label":"l","type":"text",
                 "required":false,"position":0}
                """#
            )
        )
    }

    // MARK: - Slots

    /// ⛔ `host_ids` IS NULL ON A `fixed` EVENT TYPE, where there is one host and
    /// the slot does not name them. Reading that null as "nobody is available"
    /// hides every slot on the commonest routing mode there is.
    func testASlotDecodesWithAndWithoutHostIds() throws {
        let named = try decode(
            SchedulingSlot.self,
            #"{"start":"2026-09-14T13:00:00Z","end":"2026-09-14T13:30:00Z","host_ids":["su_1"]}"#
        )
        XCTAssertEqual(named.start, "2026-09-14T13:00:00Z")
        XCTAssertEqual(named.end, "2026-09-14T13:30:00Z")
        XCTAssertEqual(named.hostIds, ["su_1"])

        let anonymous = try decode(
            SchedulingSlot.self,
            #"{"start":"2026-09-14T14:00:00Z","end":"2026-09-14T14:30:00Z","host_ids":null}"#
        )
        XCTAssertNil(anonymous.hostIds)
    }

    /// ⛔ AN ABSENT `taken` IS NOT AN EMPTY DIARY. It means the event type does not
    /// publish what is booked (`show_taken_slots` off); an empty array would mean
    /// it publishes and there is nothing. The two read identically on screen and
    /// are not the same claim.
    func testAnAbsentTakenListIsNilRatherThanEmpty() throws {
        let hidden = try decode(SchedulingSlots.self, #"{"slots":[]}"#)
        XCTAssertEqual(hidden.slots, [])
        XCTAssertNil(hidden.taken)
        XCTAssertNil(hidden.hosts)

        let published = try decode(
            SchedulingSlots.self,
            #"""
            {"slots":[{"start":"a","end":"b","host_ids":null}],
             "hosts":{"su_1":{"name":"Contract Member","avatar_url":"https://example.test/a.png"}},
             "taken":[]}
            """#
        )
        XCTAssertEqual(published.taken, [])
        XCTAssertEqual(published.hosts?["su_1"]?.name, "Contract Member")
        XCTAssertEqual(published.hosts?["su_1"]?.avatarUrl, "https://example.test/a.png")
    }

    /// ⚠️ `taken` IS `nullish` IN THE CATALOG, so it can arrive as an explicit null
    /// as well as absent. Both decode to nil and the difference is not recoverable
    /// — stated as a test rather than left for someone to discover while debugging
    /// an empty diary.
    func testAnExplicitlyNullTakenListIsAlsoNil() throws {
        let nulled = try decode(SchedulingSlots.self, #"{"slots":[],"taken":null}"#)
        XCTAssertNil(nulled.taken)
    }

    // MARK: - The test email

    /// ⛔ `sent: true` IS "HANDED TO THE MAIL TRANSPORT", NOT "ARRIVED", and `to` is
    /// the calling member's own address rather than anything the caller chose.
    func testTheTestEmailResultCarriesTheRecipientItChose() throws {
        let result = try decode(
            SchedulingTestEmailResult.self,
            #"{"sent":true,"to":"member@distronode.test"}"#
        )
        XCTAssertTrue(result.sent)
        XCTAssertEqual(result.to, "member@distronode.test")
    }
}
