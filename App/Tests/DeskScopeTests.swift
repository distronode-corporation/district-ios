@testable import DistrictAI
import DistrictData
import DistrictModel
import XCTest

/// Replying on and moving a Desk ticket, and the Desk settings writes, against the
/// service's recorded answers and its refusals.
///
/// ⚠️ A ``ScreenSnapshotTestCase`` ONLY FOR ITS SIGNED-IN CONTAINER: nothing here draws.
final class DeskScopeTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"
    private static let ticket = "/api/district/desk/tickets/desk_ticket_open"
    private static let settings = "/api/district/desk/settings"
    private static let logo = "/api/district/desk/logo"

    private func writes(_ transport: FixtureTransport) -> [String] {
        transport.requested.filter { !$0.hasPrefix("GET") && $0.contains("/desk/") }
    }

    // MARK: - DeskTicketModel

    private func ticketModel(
        _ replies: [String: FixtureTransport.Reply] = [:],
        role: WorkspaceRole? = .client
    ) async throws -> (DeskTicketModel, FixtureTransport) {
        var all: [String: FixtureTransport.Reply] = [Self.ticket: .fixture("district-desk-ticket")]
        all.merge(replies) { $1 }
        let transport = FixtureTransport(all)
        let model = try await DeskTicketModel(
            container: container(transport),
            workspaceId: Self.workspace,
            ticketId: "desk_ticket_open",
            role: role
        )
        await model.load()
        return (model, transport)
    }

    func testABlankReplyIsNotSendable() async throws {
        let (model, transport) = try await ticketModel()
        model.editDraft(" \n ")
        XCTAssertFalse(model.canSend)
        await model.sendReply()
        XCTAssertEqual(writes(transport), [])
    }

    func testAPostedReplyIsAppendedAndTheTicketAdopted() async throws {
        let (model, _) = try await ticketModel([
            "POST \(Self.ticket)/reply": .fixture("district-desk-ticket-reply"),
        ])
        let before = try XCTUnwrap(model.ticket).messages.count
        model.editDraft("  On it.  ")
        await model.sendReply()

        let after = try XCTUnwrap(model.ticket)
        XCTAssertEqual(after.messages.count, before + 1)
        XCTAssertEqual(after.status, "waiting", "the reply's ticket is adopted")
        XCTAssertEqual(model.draft, "")
        XCTAssertFalse(model.busy)
    }

    /// ⚠️ A REPLAYED REPLY WITH NO BODY IS SENT, NOT LOST: the box clears, the thread is
    /// re-read, and the notice says the reply went out but is not shown yet.
    func testAReplayedReplyWithoutABodyRereadsTheThread() async throws {
        let (model, transport) = try await ticketModel([
            "POST \(Self.ticket)/reply": .json(#"{"success":true,"deduplicated":true}"#),
        ])
        model.editDraft("On it.")
        await model.sendReply()

        XCTAssertEqual(model.notice, DeskCopy.replySentNotShown)
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(transport.requested.filter { $0 == "GET \(Self.ticket)" }.count, 2)
    }

    func testARefusedReplyKeepsTheDraftAndSaysWhy() async throws {
        let (model, _) = try await ticketModel(["POST \(Self.ticket)/reply": .refused(422, "Message is too long")])
        model.editDraft("On it.")
        await model.sendReply()

        XCTAssertEqual(model.notice, "Message is too long")
        XCTAssertEqual(model.draft, "On it.")
        model.editDraft("On it")
        XCTAssertNil(model.notice, "an edit retires the notice")
    }

    func testAStatusChangeIsAdoptedAndTheSameStatusIsNotSent() async throws {
        let (model, transport) = try await ticketModel([
            "POST \(Self.ticket)/status": .fixture("district-desk-ticket-status"),
        ])
        await model.setStatus(.open)
        XCTAssertEqual(writes(transport), [], "the ticket is already open")

        await model.setStatus(.resolved)
        XCTAssertEqual(model.ticket?.status, "resolved")
        XCTAssertEqual(writes(transport), ["POST \(Self.ticket)/status"])
    }

    func testARefusedStatusChangeKeepsTheStatus() async throws {
        let (model, _) = try await ticketModel(["POST \(Self.ticket)/status": .refused(500)])
        await model.setStatus(.waiting)
        XCTAssertEqual(model.ticket?.status, "open")
        XCTAssertNotNil(model.notice)
        model.dismissNotice()
        XCTAssertNil(model.notice)
    }

    func testAViewerNeitherRepliesNorMoves() async throws {
        let (model, transport) = try await ticketModel(role: .viewer)
        model.editDraft("On it.")
        await model.sendReply()
        await model.setStatus(.resolved)
        XCTAssertFalse(model.canSend)
        XCTAssertEqual(writes(transport), [])
    }

    // MARK: - DeskSettingsModel

    private func settingsModel(
        _ replies: [String: FixtureTransport.Reply] = [:],
        role: WorkspaceRole? = .client
    ) async throws -> (DeskSettingsModel, FixtureTransport) {
        let transport = FixtureTransport(replies)
        let model = try await DeskSettingsModel(
            container: container(transport),
            workspaceId: Self.workspace,
            role: role
        )
        await model.load()
        return (model, transport)
    }

    func testTheReadSeedsTheBrandDraft() async throws {
        let (model, _) = try await settingsModel()
        XCTAssertEqual(model.brandDraft, "Contract Test Desk")
        XCTAssertTrue(model.canEditDependents)
        XCTAssertNil(model.loadFailure)
    }

    func testARefusedReadLeavesNoSettings() async throws {
        let (model, _) = try await settingsModel([Self.settings: .refused(500)])
        XCTAssertNil(model.settings)
        XCTAssertNotNil(model.loadFailure)
        XCTAssertFalse(model.canEditDependents)
    }

    /// An unchanged brand name (whitespace aside) is not written; a blank one clears it.
    func testTheBrandNameIsWrittenOnlyWhenItChanged() async throws {
        let (model, transport) = try await settingsModel([
            "PATCH \(Self.settings)": .fixture("district-desk-settings-patch"),
        ])
        model.editBrandDraft("  Contract Test Desk ")
        await model.commitBrandName()
        XCTAssertEqual(writes(transport), [])

        model.editBrandDraft("   ")
        await model.commitBrandName()
        XCTAssertEqual(writes(transport), ["PATCH \(Self.settings)"])
        guard case .saved = model.save else {
            return XCTFail("expected saved, got \(model.save)")
        }
        XCTAssertEqual(model.brandDraft, "", "the answer's null name is adopted")
        XCTAssertEqual(model.settings?.enabled, false)
        XCTAssertFalse(model.canEditDependents, "a desk turned off has nothing dependent to edit")
    }

    func testARefusedSwitchIsAFailureAndCanBeDismissed() async throws {
        let (model, _) = try await settingsModel(["PATCH \(Self.settings)": .refused(500)])
        await model.setNotifyCustomers(false)
        guard case .failed = model.save else {
            return XCTFail("expected failed, got \(model.save)")
        }
        XCTAssertEqual(model.settings?.notifyCustomersByEmail, true, "the last answer stands")
        model.dismissNotice()
        guard case .idle = model.save else {
            return XCTFail("expected idle, got \(model.save)")
        }
    }

    func testALogoUploadAdoptsTheAnswer() async throws {
        let (model, _) = try await settingsModel(["POST \(Self.logo)": .fixture("district-desk-logo")])
        await model.uploadLogo(ScopeMedia.png, mimeType: "image/png")
        guard case .saved = model.save else {
            return XCTFail("expected saved, got \(model.save)")
        }
        XCTAssertFalse(model.uploading)
    }

    func testAnUnreadableLogoIsRefusedWithoutARetry() async throws {
        let (model, transport) = try await settingsModel()
        model.refuseUnreadableLogo()
        guard case let .failed(failure) = model.save, case .none = failure.action else {
            return XCTFail("expected an unretryable failure, got \(model.save)")
        }
        XCTAssertEqual(failure.message, DeskCopy.logoUnreadable)
        XCTAssertEqual(writes(transport), [])
    }

    /// ⚠️ A LOGO CLEARED BUT NOT DELETED IS SAVED, AND SAYS THE FILE SURVIVED.
    func testRemovingALogoWhoseFileSurvivedSaysSo() async throws {
        let survived = FixtureTransport.Reply.recorded("district-desk-logo-delete") { $0["objectRemoved"] = false }
        let (model, _) = try await settingsModel(["DELETE \(Self.logo)": survived])
        await model.removeLogo()
        guard case let .savedButStale(failure) = model.save else {
            return XCTFail("expected saved but stale, got \(model.save)")
        }
        XCTAssertEqual(failure.message, DeskCopy.logoClearedNotDeleted)
        XCTAssertNil(model.settings?.publicLogoUrl)

        let (clean, _) = try await settingsModel(["DELETE \(Self.logo)": .fixture("district-desk-logo-delete")])
        await clean.removeLogo()
        guard case .saved = clean.save else {
            return XCTFail("expected saved, got \(clean.save)")
        }
    }

    func testAViewerWritesNothing() async throws {
        let (model, transport) = try await settingsModel(role: .viewer)
        await model.setEnabled(false)
        await model.uploadLogo(ScopeMedia.png, mimeType: "image/png")
        await model.removeLogo()
        model.editBrandDraft("New name")
        await model.commitBrandName()
        XCTAssertEqual(writes(transport), [])
    }
}
