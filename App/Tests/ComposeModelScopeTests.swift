@testable import DistrictAI
import DistrictData
import DistrictModel
import XCTest

/// ``ComposeModel`` over the recorded contacts and send: who can be written to, on which
/// channel, when Send is allowed, and where a sent message lands.
///
/// ⚠️ IT DERIVES FROM ``ScreenSnapshotTestCase`` ONLY FOR ITS SIGNED-IN ``container(_:)``; it
/// draws nothing.
final class ComposeModelScopeTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"

    private func prepared(
        _ replies: [String: FixtureTransport.Reply] = [:],
        role: WorkspaceRole? = .client
    ) async throws -> (ComposeModel, FixtureTransport) {
        let transport = FixtureTransport(replies)
        let model = try await ComposeModel(container: container(transport), workspaceId: Self.workspace, role: role)
        await model.prepare()
        return (model, transport)
    }

    private func contact(_ model: ComposeModel, _ id: String) throws -> Contact {
        try XCTUnwrap(model.contacts.first { $0.id == id })
    }

    private func sends(_ transport: FixtureTransport) -> [String] {
        transport.requested.filter { $0 == "POST /api/district/messages/send" }
    }

    // MARK: - Suggestions

    func testPrepareReadsTheRecordedContacts() async throws {
        let (model, _) = try await prepared()
        guard case let .ready(contacts) = model.contactsState else {
            return XCTFail("contacts not ready: \(model.contactsState)")
        }
        XCTAssertEqual(contacts.map(\.id), ["contact_contract_1", "contact_contract_2"])
        XCTAssertNil(model.recipient)
        XCTAssertTrue(model.channelChoices.isEmpty)
        XCTAssertNil(model.target)
    }

    func testARefusedContactsReadIsAFailureWithNoSuggestions() async throws {
        let (model, _) = try await prepared(["/api/district/contacts": .refused(500)])
        guard case .failed = model.contactsState else {
            return XCTFail("expected a failure, got \(model.contactsState)")
        }
        XCTAssertTrue(model.contacts.isEmpty)
        XCTAssertTrue(model.matches.isEmpty)
    }

    /// Name, phone and email are matched, case-insensitively, after trimming the query.
    func testMatchesSearchNamePhoneAndEmail() async throws {
        let (model, _) = try await prepared()
        model.query = "   "
        XCTAssertEqual(model.matches.count, 2, "a blank query is every contact")
        model.query = "  SPARSE "
        XCTAssertEqual(model.matches.map(\.id), ["contact_contract_2"])
        model.query = "416555"
        XCTAssertEqual(model.matches.map(\.id), ["contact_contract_1"])
        model.query = "ADA@CONTRACT"
        XCTAssertEqual(model.matches.map(\.id), ["contact_contract_1"])
        model.query = "nobody-by-this-name"
        XCTAssertTrue(model.matches.isEmpty)
    }

    // MARK: - Recipient and channel

    func testAContactWithPhoneAndEmailOffersSmsFirstThenEmail() async throws {
        let (model, _) = try await prepared()
        try model.choose(contact(model, "contact_contract_1"))
        XCTAssertEqual(model.channelChoices.map(\.channel), [MessageChannel.sms, MessageChannel.email])
        XCTAssertEqual(model.target?.to, "14165551234")
        XCTAssertFalse(model.requiresSubject)

        model.selectChannel(1)
        XCTAssertEqual(model.target?.channel, MessageChannel.email)
        XCTAssertTrue(model.requiresSubject)
    }

    func testAChannelOutOfRangeIsIgnored() async throws {
        let (model, _) = try await prepared()
        try model.choose(contact(model, "contact_contract_1"))
        model.selectChannel(5)
        XCTAssertEqual(model.selectedChannel, 0)
        model.selectChannel(-1)
        XCTAssertEqual(model.selectedChannel, 0)
    }

    /// A blank phone or email is no channel at all, so a contact with neither offers none.
    func testBlankAddressesAreNotChannels() async throws {
        let blank: FixtureTransport.Reply = .recorded("district-contacts") { json in
            json.editEach("contacts") { row in
                row["phoneNumber"] = "   "
                row["email"] = ""
            }
        }
        let (model, _) = try await prepared(["/api/district/contacts": blank])
        try model.choose(contact(model, "contact_contract_1"))
        XCTAssertTrue(model.channelChoices.isEmpty)
        XCTAssertNil(model.target)
        XCTAssertFalse(model.canSendNow(body: "Hello", subject: ""))
    }

    func testATypedAddressIsTrimmedAndItsChannelFollowsTheAt() async throws {
        let (model, _) = try await prepared()
        model.query = "  +14165550000  "
        model.useTypedAddress()
        XCTAssertEqual(model.target, ReplyTarget(to: "+14165550000", channel: MessageChannel.sms))

        model.clearRecipient()
        XCTAssertNil(model.recipient)
        model.query = "someone@contract.test"
        model.useTypedAddress()
        XCTAssertEqual(model.target?.channel, MessageChannel.email)
    }

    func testABlankTypedAddressChoosesNothing() async throws {
        let (model, _) = try await prepared()
        model.query = " \n\t "
        model.useTypedAddress()
        XCTAssertNil(model.recipient)
    }

    func testChoosingResetsTheChannelToTheFirst() async throws {
        let (model, _) = try await prepared()
        try model.choose(contact(model, "contact_contract_1"))
        model.selectChannel(1)
        try model.choose(contact(model, "contact_contract_1"))
        XCTAssertEqual(model.selectedChannel, 0)
    }

    // MARK: - Send

    func testSendIsRefusedWithoutARecipientABodyOrAnEmailSubject() async throws {
        let (model, transport) = try await prepared()
        XCTAssertFalse(model.canSendNow(body: "Hello", subject: ""), "no recipient")

        try model.choose(contact(model, "contact_contract_1"))
        XCTAssertFalse(model.canSendNow(body: "  \n ", subject: ""), "blank body")
        XCTAssertTrue(model.canSendNow(body: "Hello", subject: ""), "SMS needs no subject")

        model.selectChannel(1)
        XCTAssertFalse(model.canSendNow(body: "Hello", subject: "   "), "email needs a subject")
        XCTAssertTrue(model.canSendNow(body: "Hello", subject: "Thursday"))

        let sent = await model.send(body: "  ", subject: "Thursday")
        XCTAssertFalse(sent)
        XCTAssertTrue(sends(transport).isEmpty, "a refused send must not reach the service")
    }

    func testAViewerCanNeverSend() async throws {
        let (model, transport) = try await prepared(role: .viewer)
        XCTAssertFalse(model.canSend)
        model.query = "+14165550000"
        model.useTypedAddress()
        XCTAssertFalse(model.canSendNow(body: "Hello", subject: ""))
        let sent = await model.send(body: "Hello", subject: "")
        XCTAssertFalse(sent)
        XCTAssertTrue(sends(transport).isEmpty)
    }

    func testAnUnparsedRoleCannotSend() async throws {
        let (model, _) = try await prepared(role: nil)
        XCTAssertFalse(model.canSend)
    }

    /// A sent message lands on the thread the service resolves it to.
    func testASentMessageLandsOnItsThread() async throws {
        let (model, transport) = try await prepared([
            "POST /api/district/messages/send": .fixture("district-message-send"),
            "/api/district/messages/msg_contract_sent": .fixture("district-message-thread"),
        ])
        model.query = "+14165551234"
        model.useTypedAddress()

        let sent = await model.send(body: "Confirmed for Thursday at 2pm.", subject: "ignored on SMS")
        XCTAssertTrue(sent)
        XCTAssertEqual(sends(transport).count, 1)
        guard case let .thread(workspaceId, role, threadKey, _, title) = model.landing else {
            return XCTFail("expected a thread route, got \(String(describing: model.landing))")
        }
        XCTAssertEqual(workspaceId, Self.workspace)
        XCTAssertEqual(role, .client)
        XCTAssertEqual(threadKey, "contact:contact_contract_1")
        XCTAssertNil(title)
    }

    /// The send landed but its thread could not be resolved: still sent, with nowhere to go.
    func testASentMessageWhoseThreadIsUnreadableLandsNowhere() async throws {
        let (model, _) = try await prepared([
            "POST /api/district/messages/send": .fixture("district-message-send"),
            "/api/district/messages/msg_contract_sent": .refused(500),
        ])
        model.query = "+14165551234"
        model.useTypedAddress()

        let sent = await model.send(body: "Hello", subject: "")
        XCTAssertTrue(sent)
        guard case .sent(.none) = model.sendState else {
            return XCTFail("expected sent with no route, got \(model.sendState)")
        }
        XCTAssertNil(model.landing)
    }

    /// A refused send keeps the recipient and says why; changing the recipient clears the failure.
    func testARefusedSendIsAFailureThatARecipientChangeClears() async throws {
        let (model, transport) = try await prepared([
            "POST /api/district/messages/send": .refused(502, "The carrier did not accept the message."),
        ])
        model.query = "+14165551234"
        model.useTypedAddress()

        let sent = await model.send(body: "Hello", subject: "")
        XCTAssertFalse(sent)
        XCTAssertEqual(sends(transport).count, 1, "never re-sent on its own")
        guard case .failed = model.sendState else {
            return XCTFail("expected a failure, got \(model.sendState)")
        }
        XCTAssertNotNil(model.recipient)
        XCTAssertNil(model.landing)

        model.clearRecipient()
        guard case .idle = model.sendState else {
            return XCTFail("a recipient change should clear the failure, got \(model.sendState)")
        }
    }

    /// Opening the sheet again starts clean.
    func testPrepareResetsEverything() async throws {
        let (model, _) = try await prepared()
        model.query = "+14165551234"
        model.useTypedAddress()
        await model.prepare()
        XCTAssertEqual(model.query, "")
        XCTAssertNil(model.recipient)
        XCTAssertEqual(model.selectedChannel, 0)
        guard case .idle = model.sendState else {
            return XCTFail("expected idle, got \(model.sendState)")
        }
    }
}
