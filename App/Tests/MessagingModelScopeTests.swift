@testable import DistrictAI
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The carrier accounts model against the service's recorded messaging responses: who may
/// edit, what each write sends and re-reads, and what each outcome leaves on screen.
///
/// ⚠️ A SUBCLASS OF ``ScreenSnapshotTestCase`` ONLY FOR ITS SIGNED-IN CONTAINER; nothing here
/// draws.
final class MessagingModelScopeTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"
    private static let path = "/api/district/workspace/messaging"
    private static let probePath = "/api/district/workspace/messaging/test"

    private func loaded(
        _ replies: [String: FixtureTransport.Reply] = [:],
        role: WorkspaceRole? = .client
    ) async throws -> (MessagingModel, FixtureTransport) {
        let transport = FixtureTransport(replies)
        let container = try await container(transport)
        let model = MessagingModel(container: container, workspaceId: Self.workspace, role: role)
        await model.loadAccounts()
        return (model, transport)
    }

    private func typeTwilio(_ model: MessagingModel) {
        model.startEditing(accountId: nil)
        guard var draft = model.draft else { return XCTFail("no draft opened") }
        draft.secrets = ["accountSid": " AC1 ", "authToken": "token"]
        model.editDraft(draft)
    }

    // MARK: - Reading and gating

    func testTheReadListsTheRecordedAccounts() async throws {
        let (model, _) = try await loaded()
        XCTAssertEqual(model.accounts.map(\.id), ["acct-twilio", "acct-telnyx"])
        XCTAssertTrue(model.canEditNow)
        XCTAssertFalse(model.busy)
    }

    /// ⛔ A FAILED READ OFFERS NOTHING TO EDIT, so no draft can be opened over it.
    func testAFailedReadCannotBeEdited() async throws {
        let (model, _) = try await loaded([Self.path: .refused(500)])
        guard case .failed = model.load else { return XCTFail("expected a failed read") }
        XCTAssertNil(model.response)
        XCTAssertFalse(model.canEditNow)
        model.startEditing(accountId: nil)
        XCTAssertNil(model.draft)
    }

    /// A viewer reads the list but every write and the draft are refused.
    func testAViewerOpensNoDraftAndSendsNoWrite() async throws {
        let (model, transport) = try await loaded(role: .viewer)
        XCTAssertFalse(model.canEdit)
        model.startEditing(accountId: "acct-twilio")
        XCTAssertNil(model.draft)
        await model.setDefault(accountId: "acct-twilio")
        await model.deleteAccount(accountId: "acct-twilio")
        XCTAssertEqual(transport.requested, ["GET \(Self.path)"])
    }

    /// An unparsed role fails closed, exactly as a viewer.
    func testAnUnparsedRoleIsReadOnly() async throws {
        let (model, _) = try await loaded(role: nil)
        XCTAssertFalse(model.canEdit)
    }

    /// An id that is not on the list opens nothing rather than a blank edit.
    func testEditingAnUnknownAccountOpensNothing() async throws {
        let (model, _) = try await loaded()
        model.startEditing(accountId: "acct-gone")
        XCTAssertNil(model.draft)
    }

    /// Editing an existing account carries its stored fields and no secrets.
    func testEditingAnAccountCarriesItsStoredFields() async throws {
        let (model, _) = try await loaded()
        model.startEditing(accountId: "acct-telnyx")
        let draft = try XCTUnwrap(model.draft)
        XCTAssertEqual(draft.accountId, "acct-telnyx")
        XCTAssertEqual(draft.provider, "telnyx")
        XCTAssertEqual(draft.credentialSource, "managed")
        XCTAssertEqual(draft.phoneNumbers, "+14165550113")
        XCTAssertFalse(draft.secretsRequired)
        XCTAssertTrue(draft.canSave)
    }

    /// ⚠️ A DRAFT CANNOT BE CONJURED by an edit when none is open; closing one is allowed.
    func testEditDraftNeedsAnOpenDraftExceptToClose() async throws {
        let (model, _) = try await loaded()
        model.editDraft(MessagingDraft())
        XCTAssertNil(model.draft)
        model.startEditing(accountId: nil)
        model.editDraft(nil)
        XCTAssertNil(model.draft)
    }

    // MARK: - Saving an account

    /// An incomplete new account sends nothing.
    func testAnIncompleteNewAccountIsNotSent() async throws {
        let (model, transport) = try await loaded()
        model.startEditing(accountId: nil)
        await model.saveAccount()
        XCTAssertEqual(transport.requested, ["GET \(Self.path)"])
        XCTAssertNotNil(model.draft)
    }

    /// A save that lands closes the draft and re-reads the list before saying "saved".
    func testASaveClosesTheDraftAndReReads() async throws {
        let (model, transport) = try await loaded(["PATCH \(Self.path)": .fixture("district-messaging-upsert")])
        typeTwilio(model)
        await model.saveAccount()
        XCTAssertNil(model.draft)
        guard case .saved = model.accountSave else { return XCTFail("expected saved, got \(model.accountSave)") }
        XCTAssertEqual(transport.requested, ["GET \(Self.path)", "PATCH \(Self.path)", "GET \(Self.path)"])
    }

    /// ⛔ A CARRIER'S 502 IS SAID IN ITS OWN WORDS, the draft survives, and nothing re-reads.
    func testACarrierRefusalKeepsTheDraftAndSaysWhy() async throws {
        let (model, transport) = try await loaded(["PATCH \(Self.path)": .refused(502, "Twilio says no")])
        typeTwilio(model)
        await model.saveAccount()
        XCTAssertNotNil(model.draft)
        guard case let .failed(failure) = model.accountSave else { return XCTFail("expected a failure") }
        XCTAssertEqual(failure.message, "Twilio says no")
        XCTAssertEqual(transport.requested.last, "PATCH \(Self.path)")
    }

    /// Any other refusal is the ordinary failure text, not the server's raw words.
    func testAnotherRefusalIsTheOrdinaryFailure() async throws {
        let (model, _) = try await loaded(["PATCH \(Self.path)": .refused(500, "stack trace")])
        typeTwilio(model)
        await model.saveAccount()
        guard case let .failed(failure) = model.accountSave else { return XCTFail("expected a failure") }
        XCTAssertEqual(failure.message, SessionCopy.somethingWentWrongOur)
    }

    // MARK: - Row writes

    func testSettingTheDefaultReReadsTheList() async throws {
        let (model, transport) = try await loaded(["PATCH \(Self.path)": .fixture("district-messaging-set-default")])
        await model.setDefault(accountId: "acct-twilio")
        guard case .saved = model.defaultSave else { return XCTFail("expected saved") }
        XCTAssertEqual(transport.requested.count, 3)
    }

    /// ⚠️ A REFUSED ROW WRITE RE-READS TOO, and says it failed.
    func testARefusedChannelDefaultReReadsAndFails() async throws {
        let (model, transport) = try await loaded(["PATCH \(Self.path)": .refused(409, "Not that one")])
        await model.setChannelDefault(channel: "sms", accountId: "acct-telnyx")
        guard case .failed = model.channelSave else { return XCTFail("expected a failure") }
        XCTAssertEqual(transport.requested, ["GET \(Self.path)", "PATCH \(Self.path)", "GET \(Self.path)"])
        XCTAssertTrue(model.canEditNow)
    }

    func testDeletingAnAccountReReadsTheList() async throws {
        let (model, _) = try await loaded(["PATCH \(Self.path)": .fixture("district-messaging-delete")])
        await model.deleteAccount(accountId: "acct-telnyx")
        guard case .saved = model.deleteSave else { return XCTFail("expected saved") }
        model.dismissNotices()
        guard case .idle = model.deleteSave else { return XCTFail("expected the notice dismissed") }
    }

    // MARK: - The Meta creator cell

    /// A blank or whitespace number sends nothing.
    func testABlankCreatorCellIsNotSent() async throws {
        let (model, transport) = try await loaded()
        model.editCreatorCell("   ")
        XCTAssertFalse(model.canSaveCreatorCell)
        await model.saveCreatorCell()
        XCTAssertEqual(transport.requested.count, 1)
    }

    /// A saved number clears the box; a refused one stays typed.
    func testTheCreatorCellClearsOnlyOnSuccess() async throws {
        let (saved, _) = try await loaded(["PATCH \(Self.path)": .fixture("district-messaging-meta")])
        saved.editCreatorCell(" +14165550100 ")
        await saved.saveCreatorCell()
        XCTAssertEqual(saved.creatorCellDraft, "")
        guard case .saved = saved.metaSave else { return XCTFail("expected saved") }

        let (refused, _) = try await loaded(["PATCH \(Self.path)": .refused(400, "Not a mobile number")])
        refused.editCreatorCell("+14165550100")
        await refused.saveCreatorCell()
        XCTAssertEqual(refused.creatorCellDraft, "+14165550100")
        guard case .failed = refused.metaSave else { return XCTFail("expected a failure") }
        refused.editCreatorCell("+1")
        guard case .idle = refused.metaSave else { return XCTFail("an edit retires the notice") }
    }

    // MARK: - The probe

    func testAProbeThatPassesNamesTheAccount() async throws {
        let (model, _) = try await loaded()
        typeTwilio(model)
        await model.testCredentials()
        guard case let .passed(detail) = model.probe else { return XCTFail("expected passed, got \(model.probe)") }
        XCTAssertEqual(detail, "Distronode Contract")
    }

    func testAProbeTheCarrierRefusedForwardsItsWords() async throws {
        let (model, _) = try await loaded([Self.probePath: .fixture("district-messaging-test-rejected")])
        typeTwilio(model)
        await model.testCredentials()
        guard case let .rejected(message) = model.probe else { return XCTFail("expected rejected") }
        XCTAssertEqual(message, "Authenticate (20003)")
    }

    /// ⚠️ A BLANK REFUSAL COUNTS AS ABSENT, and the screen's own sentence stands in.
    func testABlankRefusalFallsBackToTheScreensSentence() async throws {
        let (model, _) = try await loaded([Self.probePath: .json(#"{"success":false,"error":"   "}"#)])
        typeTwilio(model)
        await model.testCredentials()
        guard case let .rejected(message) = model.probe else { return XCTFail("expected rejected") }
        XCTAssertEqual(message, SettingsCopy.carrierRefusedThoseCredentials)
    }

    /// ⛔ A PROBE THAT COULD NOT BE ASKED is unreachable, never "your keys are wrong".
    func testAProbeThatCouldNotBeAskedIsUnreachable() async throws {
        let (model, _) = try await loaded([Self.probePath: .refused(503)])
        typeTwilio(model)
        await model.testCredentials()
        guard case .unreachable = model.probe else { return XCTFail("expected unreachable") }
    }

    /// A draft missing a box is not probed, and any edit retires a previous answer.
    func testAnIncompleteDraftIsNotProbedAndAnEditRetiresTheAnswer() async throws {
        let (model, transport) = try await loaded()
        model.startEditing(accountId: nil)
        await model.testCredentials()
        XCTAssertEqual(transport.requested.count, 1)
        typeTwilio(model)
        await model.testCredentials()
        guard case .passed = model.probe else { return XCTFail("expected passed") }
        guard var draft = model.draft else { return XCTFail("no draft") }
        draft.label = "Edited"
        model.editDraft(draft)
        guard case .idle = model.probe else { return XCTFail("expected the answer retired") }
    }
}
