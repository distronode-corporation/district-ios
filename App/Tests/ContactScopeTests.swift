@testable import DistrictAI
import DistrictModel
import XCTest

/// Adding a contact, changing one, and starting a video call with one, against the
/// service's recorded answers and its refusals.
///
/// ⚠️ A ``ScreenSnapshotTestCase`` ONLY FOR ITS SIGNED-IN CONTAINER: nothing here draws.
final class ContactScopeTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"
    private static let detail = "/api/district/contacts/get"
    private static let create = "POST /api/district/contacts/create"

    private func writes(_ transport: FixtureTransport) -> [String] {
        transport.requested.filter { !$0.hasPrefix("GET") && $0.contains("/contacts") }
    }

    // MARK: - ContactsModel

    private func contactsModel(
        _ replies: [String: FixtureTransport.Reply] = [:],
        role: WorkspaceRole? = .client
    ) async throws -> (ContactsModel, FixtureTransport) {
        let transport = FixtureTransport(replies)
        let model = try await ContactsModel(container: container(transport), workspaceId: Self.workspace, role: role)
        return (model, transport)
    }

    func testACreateWithoutANameOrAnAddressSendsNothing() async throws {
        let (model, transport) = try await contactsModel()
        await model.create(name: "   ", phoneNumber: "+14165551234", email: "")
        await model.create(name: "Ada", phoneNumber: "  ", email: "\n")

        guard case .idle = model.createState else {
            return XCTFail("expected idle, got \(model.createState)")
        }
        XCTAssertEqual(writes(transport), [])
    }

    func testAViewerCannotCreate() async throws {
        let (model, transport) = try await contactsModel(role: .viewer)
        await model.create(name: "Ada", phoneNumber: "+14165551234", email: "")
        XCTAssertFalse(model.canMutate)
        XCTAssertEqual(writes(transport), [])
    }

    func testACreatedContactNamesItsIdAndRefreshesTheList() async throws {
        let (model, transport) = try await contactsModel([
            Self.create: .json(#"{"success":true,"id":"contact_new"}"#),
        ])
        await model.create(name: " Ada ", phoneNumber: "", email: "ada@contract.test")

        guard case let .created(id) = model.createState else {
            return XCTFail("expected created, got \(model.createState)")
        }
        XCTAssertEqual(id, "contact_new")
        XCTAssertTrue(transport.requested.contains("GET /api/district/contacts"), "the list is re-read")
    }

    func testARefusedCreateShowsTheServersSentence() async throws {
        let sentence = "A contact with this phone number already exists"
        let (model, _) = try await contactsModel([Self.create: .refused(409, sentence)])
        await model.create(name: "Ada", phoneNumber: "+14165551234", email: "")

        guard case let .failed(failure) = model.createState else {
            return XCTFail("expected failed, got \(model.createState)")
        }
        XCTAssertEqual(failure.message, sentence)
    }

    // MARK: - ContactDetailModel

    private func detailModel(
        _ replies: [String: FixtureTransport.Reply] = [:],
        role: WorkspaceRole? = .client
    ) async throws -> (ContactDetailModel, FixtureTransport) {
        var all: [String: FixtureTransport.Reply] = [Self.detail: .fixture("district-contact-detail")]
        all.merge(replies) { $1 }
        let transport = FixtureTransport(all)
        let model = try await ContactDetailModel(
            container: container(transport),
            workspaceId: Self.workspace,
            contactId: "contact_contract_1",
            role: role
        )
        await model.load()
        return (model, transport)
    }

    private func loaded(_ model: ContactDetailModel) -> LoadedContact? {
        guard case let .content(loaded) = model.state else { return nil }
        return loaded
    }

    func testARenameToTheSameOrABlankNameSendsNothing() async throws {
        let (model, transport) = try await detailModel()
        await model.rename(to: "  ")
        await model.rename(to: " Contract Test Caller ")
        XCTAssertEqual(writes(transport), [])
        XCTAssertEqual(loaded(model)?.saving, false, "a refused rename does not hold the screen")
    }

    func testARenameIsWrittenAndTheRecordReread() async throws {
        let (model, transport) = try await detailModel([
            "PATCH /api/district/contacts/update": .fixture("district-contact-update"),
        ])
        await model.rename(to: "Ada Lovelace")
        XCTAssertEqual(writes(transport), ["PATCH /api/district/contacts/update"])
        XCTAssertEqual(transport.requested.filter { $0 == "GET \(Self.detail)" }.count, 2)
        XCTAssertEqual(loaded(model)?.saving, false)
    }

    /// The recorded contact's research is complete, so it is neither re-runnable nor in
    /// progress, but it can be cleared.
    func testCompletedResearchIsClearableNotEnrichable() async throws {
        let (model, transport) = try await detailModel()
        XCTAssertFalse(model.isEnrichable)
        XCTAssertFalse(model.isEnriching)
        XCTAssertTrue(model.isClearable)

        await model.enrich()
        XCTAssertEqual(writes(transport), [], "complete research is not run again")
    }

    func testAnEnrichmentRefusalIsTheServersSentenceAndCanBeDismissed() async throws {
        let bare = FixtureTransport.Reply.recorded("district-contact-detail") { json in
            json.editObject("contact") { contact in
                contact["dgiStatus"] = NSNull()
                contact["company"] = NSNull()
                contact["intelligence"] = NSNull()
            }
        }
        let refusal = "Lead enrichment is off for this workspace."
        let (model, _) = try await detailModel([
            Self.detail: bare,
            "POST /api/district/contacts/enrich": .refused(403, refusal),
        ])
        XCTAssertTrue(model.isEnrichable)
        XCTAssertFalse(model.isClearable)

        await model.enrich()
        XCTAssertEqual(loaded(model)?.mutationFailure?.message, refusal)
        XCTAssertEqual(loaded(model)?.saving, false)

        model.clearMutationFailure()
        XCTAssertNil(loaded(model)?.mutationFailure)
    }

    func testClearingResearchRereadsAndAFailedDeleteKeepsTheScreen() async throws {
        let (model, transport) = try await detailModel([
            "POST /api/district/contacts/clear-intel": .fixture("district-clear-intel"),
            "DELETE /api/district/contacts/delete": .refused(500),
        ])
        await model.clearIntel()
        let deleted = await model.delete()

        XCTAssertFalse(deleted)
        XCTAssertNotNil(loaded(model)?.mutationFailure)
        XCTAssertEqual(
            writes(transport),
            ["POST /api/district/contacts/clear-intel", "DELETE /api/district/contacts/delete"]
        )
    }

    func testADeleteThatLandsPops() async throws {
        let (model, _) = try await detailModel([
            "DELETE /api/district/contacts/delete": .fixture("district-contact-delete"),
        ])
        let deleted = await model.delete()
        XCTAssertTrue(deleted)
    }

    func testAViewerChangesNothing() async throws {
        let (model, transport) = try await detailModel(role: .viewer)
        await model.rename(to: "Ada Lovelace")
        await model.clearIntel()
        let deleted = await model.delete()
        XCTAssertFalse(deleted)
        XCTAssertEqual(writes(transport), [])
    }

    func testAMissingContactIsNotAvailableWithoutARetry() async throws {
        let (model, _) = try await detailModel([Self.detail: .refused(404, "Contact not found")])
        guard case let .failed(failure) = model.state else {
            return XCTFail("expected failed, got \(model.state)")
        }
        XCTAssertEqual(failure.message, ContactsCopy.contactNotAvailable)
        guard case .none = failure.action else {
            return XCTFail("a missing contact offers no retry")
        }
    }

    // MARK: - ContactVideoCallModel

    private static func contact(phone: String?, email: String?) throws -> Contact {
        let json = #"{"id":"c1","workspaceId":"ws-contract-test","name":"Ada","createdAt":"2026-08-15T14:30:00.000Z","#
            + #""phoneNumber":\#(phone.map { "\"\($0)\"" } ?? "null"),"#
            + #""email":\#(email.map { "\"\($0)\"" } ?? "null")}"#
        return try JSONDecoder().decode(Contact.self, from: Data(json.utf8))
    }

    func testAVideoCallGoesToThePhoneFirstThenTheMailbox() throws {
        let both = try Self.contact(phone: "+14165551234", email: "ada@contract.test")
        XCTAssertEqual(ContactVideoCallModel.target(for: both), ReplyTarget(to: "+14165551234", channel: "sms"))

        let blankPhone = try Self.contact(phone: "   ", email: " ada@contract.test ")
        XCTAssertEqual(
            ContactVideoCallModel.target(for: blankPhone),
            ReplyTarget(to: "ada@contract.test", channel: "email")
        )

        XCTAssertNil(try ContactVideoCallModel.target(for: Self.contact(phone: "", email: nil)))
    }

    private func videoRequests(_ transport: FixtureTransport) -> [String] {
        transport.requested.filter { $0.hasSuffix("/calls/token") || $0.hasSuffix("/messages/send") }
    }

    private func videoModel(
        _ replies: [String: FixtureTransport.Reply],
        role: WorkspaceRole? = .client
    ) async throws -> (ContactVideoCallModel, FixtureTransport) {
        let transport = FixtureTransport(replies)
        let model = try await ContactVideoCallModel(
            container: container(transport),
            workspaceId: Self.workspace,
            role: role
        )
        return (model, transport)
    }

    func testAContactWithNowhereToSendIsRefusedWithoutARequest() async throws {
        let (model, transport) = try await videoModel([:])
        try await model.start(with: Self.contact(phone: nil, email: nil))

        guard case let .failed(failure) = model.phase else {
            return XCTFail("expected failed, got \(model.phase)")
        }
        XCTAssertEqual(failure.message, ContactVideoCopy.noAddress)
        XCTAssertEqual(videoRequests(transport), [])

        model.reset()
        guard case .idle = model.phase else {
            return XCTFail("reset returns to idle")
        }
    }

    func testAViewerCannotStartACall() async throws {
        let (model, transport) = try await videoModel([:], role: .viewer)
        try await model.start(with: Self.contact(phone: "+14165551234", email: nil))
        XCTAssertFalse(model.canStart)
        XCTAssertEqual(videoRequests(transport), [])
    }

    func testAnInviteSentIsTheRoomToJoin() async throws {
        let (model, transport) = try await videoModel([
            "/api/district/calls/token": .fixture("district-room-token"),
            "/api/district/messages/send": .fixture("district-message-send"),
        ])
        try await model.start(with: Self.contact(phone: "+14165551234", email: nil))

        guard case let .sent(room) = model.phase else {
            return XCTFail("expected sent, got \(model.phase)")
        }
        XCTAssertTrue(room.value.contains(Self.workspace))
        XCTAssertEqual(videoRequests(transport), ["POST /api/district/calls/token", "POST /api/district/messages/send"])
    }

    func testARefusedTokenIsRetryableAndARefusedInviteIsNot() async throws {
        let (token, _) = try await videoModel(["/api/district/calls/token": .refused(500)])
        try await token.start(with: Self.contact(phone: "+14165551234", email: nil))
        guard case let .failed(tokenFailure) = token.phase, case .retry = tokenFailure.action else {
            return XCTFail("a refused token is retryable, got \(token.phase)")
        }

        let sentence = "This number has opted out of messages"
        let (invite, _) = try await videoModel([
            "/api/district/calls/token": .fixture("district-room-token"),
            "/api/district/messages/send": .refused(409, sentence),
        ])
        try await invite.start(with: Self.contact(phone: "+14165551234", email: nil))
        guard case let .failed(inviteFailure) = invite.phase, case .none = inviteFailure.action else {
            return XCTFail("a refused invite is not retryable, got \(invite.phase)")
        }
        XCTAssertEqual(inviteFailure.message, sentence)
    }
}
