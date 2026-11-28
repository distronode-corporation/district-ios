@testable import DistrictAI
import DistrictModel
import Foundation
import XCTest

/// The members model against the service's recorded member responses: who may add, change
/// and remove, what an address must look like before it is sent, and what each refusal says.
///
/// ⚠️ A SUBCLASS OF ``ScreenSnapshotTestCase`` ONLY FOR ITS SIGNED-IN CONTAINER; nothing here
/// draws.
final class MembersModelScopeTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"
    private static let path = "/api/district/workspace/members"

    private func loaded(
        _ replies: [String: FixtureTransport.Reply] = [:],
        role: WorkspaceRole? = .agency
    ) async throws -> (MembersModel, FixtureTransport) {
        let transport = FixtureTransport(replies)
        let container = try await container(transport)
        let model = MembersModel(container: container, workspaceId: Self.workspace, role: role)
        await model.load()
        return (model, transport)
    }

    // MARK: - Gating

    func testTheRosterIsTheRecordedOne() async throws {
        let (model, _) = try await loaded()
        XCTAssertTrue(model.loaded)
        XCTAssertEqual(model.members.map(\.email), [
            "founder@contract.test", "operator@contract.test", "auditor@contract.test",
        ])
        XCTAssertEqual(model.roleOptions, WorkspaceRole.allCases)
    }

    /// ⛔ ONLY AGENCY MANAGES MEMBERS; a client may still rename, a viewer may do neither.
    func testWhoMayManageAndWhoMayRename() async throws {
        let (agency, _) = try await loaded()
        XCTAssertTrue(agency.canManage)
        XCTAssertTrue(agency.canRename)
        let (client, _) = try await loaded(role: .client)
        XCTAssertFalse(client.canManage)
        XCTAssertTrue(client.canRename)
        let (viewer, _) = try await loaded(role: .viewer)
        XCTAssertFalse(viewer.canManage)
        XCTAssertFalse(viewer.canRename)
        let (unparsed, _) = try await loaded(role: nil)
        XCTAssertFalse(unparsed.canManage)
        XCTAssertFalse(unparsed.canRename)
    }

    /// A client's add, role change and removal send nothing, even with a valid address.
    func testAClientSendsNoMembershipWrite() async throws {
        let (model, transport) = try await loaded(role: .client)
        model.editEmail("new@contract.test")
        XCTAssertFalse(model.canAdd)
        await model.addMember()
        await model.changeRole(email: "operator@contract.test", to: .viewer)
        await model.removeMember(email: "auditor@contract.test")
        XCTAssertEqual(transport.requested, ["GET \(Self.path)"])
        XCTAssertFalse(model.addRejected)
    }

    func testAFailedRosterReadIsNotLoaded() async throws {
        let (model, _) = try await loaded([Self.path: .refused(500)])
        XCTAssertFalse(model.loaded)
        XCTAssertTrue(model.members.isEmpty)
        model.editName("New name")
        XCTAssertFalse(model.canRenameNow)
    }

    // MARK: - Adding

    /// ⛔ HOSTILE ADDRESSES ARE REFUSED HERE, said under the box, and nothing is sent.
    func testAddressesThatDoNotLookLikeEmailAreRefused() async throws {
        let (model, transport) = try await loaded()
        for address in [
            "",
            "   ",
            "plain",
            "a@b",
            "@contract.test",
            "a@.test",
            "a@contract.",
            "a b@contract.test",
            "a@b@contract.test",
            "a@contract .test",
        ] {
            model.editEmail(address)
            XCTAssertFalse(model.canAdd, "\(address) should not be addable")
            await model.addMember()
            XCTAssertTrue(model.addRejected, "\(address) should be refused")
        }
        XCTAssertEqual(transport.requested, ["GET \(Self.path)"])
        model.editEmail("x")
        XCTAssertFalse(model.addRejected, "an edit retires the refusal")
    }

    /// The address is trimmed and lowercased as the route stores it, and the box clears.
    func testAValidAddressIsSentNormalisedAndTheRosterReRead() async throws {
        let (model, transport) = try await loaded(["POST \(Self.path)": .fixture("district-member-add")])
        model.editEmail("  NewComer@Contract.TEST ")
        model.editRole(.viewer)
        XCTAssertTrue(model.canAdd)
        await model.addMember()
        XCTAssertEqual(model.draftEmail, "")
        XCTAssertEqual(model.draftRole, .viewer)
        guard case .saved = model.addSave else { return XCTFail("expected saved, got \(model.addSave)") }
        XCTAssertEqual(transport.requested, ["GET \(Self.path)", "POST \(Self.path)", "GET \(Self.path)"])
    }

    /// ⚠️ A DUPLICATE IS SAID IN THE SERVICE'S WORDS, the box keeps the address, and the roster
    /// is re-read because the refusal means the screen's copy was out of date.
    func testADuplicateIsSaidAndReReads() async throws {
        let (model, transport) = try await loaded([
            "POST \(Self.path)": FixtureTransport.Reply(
                status: 409,
                body: FixtureTransport.fixtureData("district-member-duplicate")
            ),
        ])
        model.editEmail("operator@contract.test")
        await model.addMember()
        guard case let .failed(failure) = model.addSave else { return XCTFail("expected a failure") }
        XCTAssertEqual(failure.message, "That email is already a member of this workspace")
        XCTAssertEqual(model.draftEmail, "operator@contract.test")
        XCTAssertEqual(transport.requested.last, "GET \(Self.path)")
    }

    /// A 409 with no sentence falls back to the screen's own.
    func testABlankConflictFallsBackToTheScreensSentence() async throws {
        let (model, _) = try await loaded(["POST \(Self.path)": .json(#"{"success":false,"error":" "}"#, status: 409)])
        model.editEmail("operator@contract.test")
        await model.addMember()
        guard case let .failed(failure) = model.addSave else { return XCTFail("expected a failure") }
        XCTAssertEqual(failure.message, SettingsCopy.membersDuplicate)
    }

    // MARK: - Role and removal

    /// ⛔ THE LAST AGENCY MEMBER CANNOT BE DEMOTED, and the service says why.
    func testDemotingTheLastAgencyMemberIsRefused() async throws {
        let (model, _) = try await loaded([
            "PATCH \(Self.path)": FixtureTransport.Reply(
                status: 409,
                body: FixtureTransport.fixtureData("district-member-last-agency")
            ),
        ])
        await model.changeRole(email: "founder@contract.test", to: .client)
        guard case let .failed(failure) = model.roleSave else { return XCTFail("expected a failure") }
        XCTAssertTrue(failure.message.hasPrefix("Cannot demote the last agency member"))
        XCTAssertTrue(model.loaded)
    }

    /// A conflict on removal with no sentence names the last-agency rule.
    func testABlankRemovalConflictNamesTheLastAgencyRule() async throws {
        let (model, _) = try await loaded(["DELETE \(Self.path)": .json(#"{"success":false}"#, status: 409)])
        await model.removeMember(email: "founder@contract.test")
        guard case let .failed(failure) = model.removeSave else { return XCTFail("expected a failure") }
        XCTAssertEqual(failure.message, SettingsCopy.membersLastAgency)
    }

    /// A refusal that is not a conflict is the ordinary failure text.
    func testANonConflictRefusalIsTheOrdinaryFailure() async throws {
        let (model, _) = try await loaded(["DELETE \(Self.path)": .refused(500, "stack trace")])
        await model.removeMember(email: "auditor@contract.test")
        guard case let .failed(failure) = model.removeSave else { return XCTFail("expected a failure") }
        XCTAssertEqual(failure.message, SessionCopy.somethingWentWrongOur)
    }

    func testARemovalThatLandsReReadsAndCanBeDismissed() async throws {
        let (model, transport) = try await loaded(["DELETE \(Self.path)": .fixture("district-member-remove")])
        await model.removeMember(email: "auditor@contract.test")
        guard case .saved = model.removeSave else { return XCTFail("expected saved") }
        XCTAssertEqual(transport.requested.count, 3)
        model.dismissNotices()
        guard case .idle = model.removeSave else { return XCTFail("expected dismissed") }
    }

    func testARoleChangeThatLandsReReads() async throws {
        let (model, _) = try await loaded(["PATCH \(Self.path)": .fixture("district-member-role-patch")])
        await model.changeRole(email: "operator@contract.test", to: .client)
        guard case .saved = model.roleSave else { return XCTFail("expected saved") }
    }

    // MARK: - Renaming

    /// Blank and over-long names are not offered.
    func testBlankAndOverlongNamesCannotBeSaved() async throws {
        let (model, transport) = try await loaded(role: .client)
        model.editName("   \n")
        XCTAssertFalse(model.canRenameNow)
        model.editName(String(repeating: "x", count: WorkspaceMembership.maxWorkspaceNameLength + 1))
        XCTAssertFalse(model.canRenameNow)
        await model.rename()
        model.editName(" " + String(repeating: "x", count: WorkspaceMembership.maxWorkspaceNameLength) + " ")
        XCTAssertTrue(model.canRenameNow, "the limit is on the trimmed name")
        XCTAssertEqual(transport.requested, ["GET \(Self.path)"])
    }

    /// A rename that lands names what the service stored and clears the box.
    func testARenameNamesWhatWasStored() async throws {
        let (model, _) = try await loaded(role: .client)
        model.editName("  Renamed Workspace ")
        await model.rename()
        XCTAssertEqual(model.storedName, "Renamed Workspace")
        XCTAssertEqual(model.renameDraft, "")
        guard case .saved = model.renameSave else { return XCTFail("expected saved") }
        model.editName("Again")
        guard case .idle = model.renameSave else { return XCTFail("an edit retires the notice") }
    }

    /// ⚠️ A REFUSED RENAME KEEPS THE TYPED NAME.
    func testARefusedRenameKeepsTheTypedName() async throws {
        let (model, _) = try await loaded(
            ["/api/district/workspace/rename": .refused(400, "Too similar")],
            role: .client
        )
        model.editName("Renamed")
        await model.rename()
        XCTAssertEqual(model.renameDraft, "Renamed")
        XCTAssertNil(model.storedName)
        guard case let .failed(failure) = model.renameSave else { return XCTFail("expected a failure") }
        XCTAssertEqual(failure.message, "Too similar")
    }
}
