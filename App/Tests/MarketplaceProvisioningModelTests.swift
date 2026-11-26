@testable import DistrictAI
import DistrictData
import DistrictL10n
import DistrictModel
import XCTest

/// ``NumberProvisioningModel`` against the service's recorded replies: which writes re-arm after
/// a failure and which do not, what a viewer may send, and how each answer lands in state.
///
/// ⚠️ A ``ScreenSnapshotTestCase`` ONLY FOR ITS SIGNED-IN CONTAINER; nothing here is drawn.
final class MarketplaceProvisioningModelTests: ScreenSnapshotTestCase {
    private static let release = "/api/district/workspace/numbers/release"
    private static let configure = "/api/district/workspace/numbers/configure"
    private static let lookup = "/api/district/workspace/lookup"
    private static let registrations = "/api/district/workspace/numbers/registrations"
    private static let submit = "/api/district/workspace/numbers/registrations/submit"

    private func makeModel(
        _ replies: [String: FixtureTransport.Reply],
        role: WorkspaceRole? = .client
    ) async throws -> (NumberProvisioningModel, FixtureTransport) {
        let transport = FixtureTransport(replies)
        let container = try await container(transport)
        return (NumberProvisioningModel(container: container, workspaceId: "ws-contract-test", role: role), transport)
    }

    /// The provisioning requests `transport` was sent, in order, without the session's own.
    private static func sent(_ transport: FixtureTransport) -> [String] {
        transport.requested.filter { $0.contains("/api/district/workspace/") }
    }

    // MARK: - Irreversible writes

    /// ⛔ A release whose answer was lost is never offered again: no confirmation reopens, and
    /// a second call sends nothing.
    func testAnUnconfirmedReleaseDisarmsTheControlForGood() async throws {
        let (model, transport) = try await makeModel([Self.release: .refused(500)])
        model.requestConfirmation(.release(phoneNumber: "+14165550100"))
        XCTAssertEqual(model.confirmation, .release(phoneNumber: "+14165550100"))

        await model.release(phoneNumber: "+14165550100")
        XCTAssertNil(model.confirmation, "the dialog closes on the attempt")
        XCTAssertFalse(model.numberWrite.isArmed)
        XCTAssertTrue(model.numberWrite.refusedRepeat)
        XCTAssertTrue(model.numberWrite.isFailure)

        model.requestConfirmation(.release(phoneNumber: "+14165550100"))
        XCTAssertNil(model.confirmation, "an unarmed write opens no confirmation")
        await model.release(phoneNumber: "+14165550100")
        await model.configure(phoneNumber: "+14165550100")
        XCTAssertEqual(Self.sent(transport), ["POST \(Self.release)"], "nothing is sent after the lost answer")
    }

    /// A 4xx proves the release did not land, so the control comes back with the refusal shown.
    func testARefusedReleaseReArms() async throws {
        let (model, _) = try await makeModel([Self.release: .refused(409, "Still assigned to a rule.")])
        await model.release(phoneNumber: "+14165550100")
        XCTAssertTrue(model.numberWrite.isArmed)
        XCTAssertFalse(model.numberWrite.refusedRepeat)
        XCTAssertEqual(model.numberWrite.notice, "Still assigned to a rule.")
        model.requestConfirmation(.release(phoneNumber: "+14165550100"))
        XCTAssertEqual(model.confirmation, .release(phoneNumber: "+14165550100"))
    }

    /// A release that could not end its charge is a done notice naming the warning, not a failure.
    func testAReleaseWithWarningsIsDoneAndNamesThem() async throws {
        let (model, _) = try await makeModel([Self.release: .fixture("district-number-release-warnings")])
        await model.release(phoneNumber: "+14165550100")
        XCTAssertFalse(model.numberWrite.isFailure)
        let notice = try XCTUnwrap(model.numberWrite.notice)
        XCTAssertTrue(notice.hasPrefix(MarketplaceCopy.releaseWarningEyebrow), notice)
        XCTAssertTrue(notice.contains("monthly charge"), notice)

        let (clean, _) = try await makeModel([Self.release: .fixture("district-number-release")])
        await clean.release(phoneNumber: "+14165550100")
        XCTAssertEqual(clean.numberWrite.notice, MarketplaceCopy.releaseDone)
    }

    /// Configure converges, so even a 5xx leaves it armed.
    func testAFailedConfigureStaysArmed() async throws {
        let (model, _) = try await makeModel([Self.configure: .refused(500)])
        await model.configure(phoneNumber: "+14165550100")
        XCTAssertTrue(model.numberWrite.isFailure)
        XCTAssertTrue(model.numberWrite.isArmed)
        XCTAssertFalse(model.numberWrite.refusedRepeat)
    }

    // MARK: - The billable lookup

    /// A blank number sends nothing; a padded one is trimmed and its answer drawn.
    func testTheLookupSendsOnlyANonBlankNumber() async throws {
        let (model, transport) = try await makeModel([Self.lookup: .fixture("district-number-lookup")])
        model.lookupNumber = "   \n"
        await model.lookup()
        XCTAssertEqual(Self.sent(transport), [])
        XCTAssertNil(model.lookupResult)

        model.lookupNumber = " +14165550142 "
        await model.lookup()
        XCTAssertEqual(Self.sent(transport), ["GET \(Self.lookup)"])
        XCTAssertEqual(model.lookupResult?.lines, ["+14165550142", "CA", "mobile", "ExampleMobile"])
        XCTAssertTrue(model.lookupWrite.isArmed)
    }

    /// An unrecognised number is one line saying so, not the nulls the carrier sent.
    func testAnInvalidLookupIsOneSentence() async throws {
        let (model, _) = try await makeModel([Self.lookup: .fixture("district-number-lookup-invalid")])
        model.lookupNumber = "+15555550100"
        await model.lookup()
        XCTAssertEqual(model.lookupResult?.lines, [MarketplaceCopy.lookupInvalid])
    }

    /// Blank and whitespace details count as absent.
    func testALookupSummaryDropsBlankDetails() throws {
        let body = #"{"valid":true,"phoneNumber":"+14165550142","country":"  ","type":"","carrier":" Rogers "}"#
        let info = try JSONDecoder().decode(NumberLookupInfo.self, from: Data(body.utf8))
        XCTAssertEqual(NumberLookupSummary(info).lines, ["+14165550142", "Rogers"])
    }

    /// ⛔ A lost lookup answer is never re-sent: the carrier billed it either way.
    func testAnUnconfirmedLookupIsNotRepeated() async throws {
        let (model, transport) = try await makeModel([Self.lookup: .refused(500)])
        model.lookupNumber = "+14165550142"
        await model.lookup()
        XCTAssertTrue(model.lookupWrite.refusedRepeat)
        model.requestConfirmation(.lookup(phoneNumber: "+14165550142"))
        XCTAssertNil(model.confirmation)
        await model.lookup()
        XCTAssertEqual(Self.sent(transport).count, 1)
    }

    // MARK: - Viewer

    /// A viewer opens no confirmation and sends no write, and the role-gated filing read is
    /// answered locally as an empty list.
    func testAViewerSendsNothingRoleGated() async throws {
        let (model, transport) = try await makeModel([:], role: .viewer)
        XCTAssertFalse(model.canProvision)
        model.requestConfirmation(.a2p)
        XCTAssertNil(model.confirmation)
        model.lookupNumber = "+14165550142"
        await model.lookup()
        await model.release(phoneNumber: "+14165550100")
        await model.configure(phoneNumber: "+14165550100")
        await model.setVerify(enabled: true)
        await model.loadRegistrations()
        XCTAssertEqual(Self.sent(transport), [])
        guard case let .ready(rows, approved, platform) = model.registrations else {
            return XCTFail("expected an empty ready list, got \(model.registrations)")
        }
        XCTAssertTrue(rows.isEmpty && approved.isEmpty && platform.isEmpty)
    }

    /// An unparsed role (nil) is read-only, never "assume client".
    func testAnUnknownRoleCannotProvision() async throws {
        let (model, _) = try await makeModel([:], role: nil)
        XCTAssertFalse(model.canProvision)
    }

    /// Closing a confirmation is always allowed, even while its write is unarmed.
    func testClosingAConfirmationIsNeverGated() async throws {
        let (model, _) = try await makeModel([:])
        model.requestConfirmation(.a2p)
        XCTAssertEqual(model.confirmation, .a2p)
        model.requestConfirmation(nil)
        XCTAssertNil(model.confirmation)
        model.requestConfirmation(.tfv(phoneNumber: "+18005550188"))
        model.dismissConfirmation()
        XCTAssertNil(model.confirmation)
    }

    // MARK: - Registrations

    /// A 422 points at the list, where the carrier's objections are, and re-arms.
    func testA422SubmitQuotesTheCarrierAndReArms() async throws {
        let (model, transport) = try await makeModel([
            Self.submit: .refused(422, "The registry extract is unreadable."),
            Self.registrations: .json(MarketplaceBodies.registrationsEmpty),
        ])
        await model.submitRegistration(bundleId: "bun_1")
        guard case let .failed(failure, resubmit) = model.registrationWrite else {
            return XCTFail("expected a failure, got \(model.registrationWrite)")
        }
        XCTAssertEqual(failure.message, MarketplaceCopy.submitRefusedBecause("The registry extract is unreadable."))
        XCTAssertEqual(resubmit, .allowed)
        XCTAssertEqual(Self.sent(transport), ["POST \(Self.submit)", "GET \(Self.registrations)"], "re-read on failure")
    }

    /// A 422 with no sentence still says where to look.
    func testA422SubmitWithNoSentenceSaysToReread() async throws {
        let (model, _) = try await makeModel([
            Self.submit: .json(#"{"success":false,"error":"   "}"#, status: 422),
            Self.registrations: .json(MarketplaceBodies.registrationsEmpty),
        ])
        await model.submitRegistration(bundleId: "bun_1")
        XCTAssertEqual(
            model.registrationWrite.notice,
            MarketplaceCopy.submitRefusedBecause(MarketplaceCopy.submitRefusedReread)
        )
    }

    /// A blank country starts nothing and asks for no requirements.
    func testABlankCountryStartsNothing() async throws {
        let (model, transport) = try await makeModel([:])
        model.registrationDraft.country = "  "
        await model.createRegistration()
        await model.loadRequirements()
        XCTAssertEqual(Self.sent(transport), [])
        guard case .idle = model.requirements else {
            return XCTFail("expected idle, got \(model.requirements)")
        }
    }

    /// A failed draft is idempotent by refusal, so it re-arms even on a 5xx.
    func testAFailedCreateReArms() async throws {
        let (model, _) = try await makeModel([Self.registrations: .refused(500)])
        model.registrationDraft.country = "ee"
        await model.createRegistration()
        XCTAssertTrue(model.registrationWrite.isFailure)
        XCTAssertTrue(model.registrationWrite.isArmed)
    }

    // MARK: - Carrier accounts

    /// A body with no providers is an account state, not a failure.
    func testNoProvidersIsNotConnected() async throws {
        let (model, _) = try await makeModel([
            "/api/district/workspace/provider/status": .fixture("district-provider-status-none"),
        ])
        await model.loadCarrier()
        guard case .notConnected = model.carrier else {
            return XCTFail("expected notConnected, got \(model.carrier)")
        }
    }

    /// Connected and refused carriers are both content, each sorted by name.
    func testConnectedAndRefusedCarriersAreSeparated() async throws {
        let (model, _) = try await makeModel([:])
        await model.loadCarrier()
        guard case let .ready(entries, connected, refused) = model.carrier else {
            return XCTFail("expected ready, got \(model.carrier)")
        }
        XCTAssertEqual(connected, ["telnyx", "twilio"])
        XCTAssertEqual(refused, ["sinch"])
        XCTAssertEqual(entries.count, 3)
    }

    /// Turning Verify off adopts the reply's own answer, with no sid.
    func testVerifyAdoptsTheWritesAnswer() async throws {
        let (model, _) = try await makeModel([
            "POST /api/district/workspace/verify": .fixture("district-verify-disable"),
        ])
        await model.loadVerify()
        guard case let .ready(enabled, sid) = model.verify else {
            return XCTFail("expected the recorded read, got \(model.verify)")
        }
        XCTAssertTrue(enabled)
        XCTAssertEqual(sid, "VA_contract")
        await model.setVerify(enabled: false)
        guard case let .ready(after, afterSid) = model.verify else {
            return XCTFail("expected the disable reply, got \(model.verify)")
        }
        XCTAssertFalse(after)
        XCTAssertNil(afterSid)
        XCTAssertTrue(model.carrierWrite.isArmed)
    }

    /// An incomplete SIP form sends nothing.
    func testAnIncompleteSipTrunkSendsNothing() async throws {
        let (model, transport) = try await makeModel([:])
        model.sipDraft.name = "Desk"
        model.sipDraft.domain = "desk.sip.twilio.com"
        model.sipDraft.ipAddresses = " \n  \n"
        await model.createSipTrunk()
        model.a2pDraft.businessName = "Clinic"
        await model.submitA2P()
        model.tfvDraft.phoneNumber = "+18005550188"
        model.tfvDraft.businessName = "Clinic"
        await model.submitTollFree()
        XCTAssertEqual(Self.sent(transport), [])
    }

    /// Each filing's accepted status is named in its notice.
    func testFilingsNameTheCarriersStatus() async throws {
        let (model, _) = try await makeModel([
            "/api/district/workspace/a2p": .fixture("district-a2p-registration"),
        ])
        model.a2pDraft = A2PDraft(
            businessName: "Clinic",
            campaignDescription: "Reminders",
            sampleOne: "One",
            sampleTwo: "Two"
        )
        await model.submitA2P()
        XCTAssertEqual(
            model.carrierWrite.notice,
            MarketplaceCopy.a2pSubmitted(status: AppWire.label(.a2pRegistrationStatus, "IN_PROGRESS"))
        )
    }
}
