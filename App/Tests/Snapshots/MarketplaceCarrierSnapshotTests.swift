@testable import DistrictAI
import DistrictModel
import SwiftUI
import XCTest

/// The Carrier tab of Phone numbers, drawn as the screen draws it (carrier accounts, Verify and
/// SIP trunks, the billable lookup, then the A2P and toll-free filings) from the service's
/// recorded responses.
final class MarketplaceCarrierSnapshotTests: ScreenSnapshotTestCase {
    private static let sip = "/api/district/workspace/sip"
    private static let verify = "/api/district/workspace/verify"
    private static let status = "/api/district/workspace/provider/status"
    private static let lookup = "/api/district/workspace/lookup"

    /// The three reads the tab fires on opening, answered as recorded.
    private static let reads: [String: FixtureTransport.Reply] = [
        "GET \(sip)": .fixture("district-sip-trunks"),
    ]

    /// Three carriers (managed, connected with an account, refusing its credentials), Verify on,
    /// and two trunks, one never provisioned at the carrier; the forms below, empty.
    func testCarrierLoaded() async throws {
        try await assertScreen(Self.reads) { container in
            Self.carrierTab(container, role: .client) { await Self.open($0) }
        }
    }

    /// A viewer reads the same accounts and trunks with no control and is told who can.
    func testCarrierForAViewer() async throws {
        try await assertScreen(Self.reads, devices: [.iPhone]) { container in
            Self.carrierTab(container, role: .viewer) { await Self.open($0) }
        }
    }

    /// A new workspace: no carrier (an account state, offered no retry), Verify off and no trunks.
    func testCarrierNotConnected() async throws {
        try await assertScreen(
            [
                Self.status: .fixture("district-provider-status-none"),
                "GET \(Self.verify)": .recorded("district-verify") { json in
                    json["enabled"] = false
                    json["verifyServiceSid"] = NSNull()
                },
                "GET \(Self.sip)": .recorded("district-sip-trunks") { $0["trunks"] = [Any]() },
            ],
            devices: [.iPhone]
        ) { container in
            Self.carrierTab(container, role: .client) { await Self.open($0) }
        }
    }

    /// All three reads refused: three failure cards, each with its own retry, and the lookup and
    /// filings still offered.
    func testCarrierReadsFailed() async throws {
        try await assertScreen(
            [Self.status: .refused(500), "GET \(Self.verify)": .refused(500), "GET \(Self.sip)": .refused(500)],
            devices: [.iPhone]
        ) { container in
            Self.carrierTab(container, role: .client) { await Self.open($0) }
        }
    }

    /// A lookup the carrier answered: the number, country, type and carrier.
    func testLookupAnswered() async throws {
        var replies = Self.reads
        replies[Self.lookup] = .fixture("district-number-lookup")
        try await assertScreen(replies, devices: [.iPhone]) { container in
            Self.carrierTab(container, role: .client) { model in
                await Self.open(model)
                model.lookupNumber = " +14165550142 "
                await model.lookup()
            }
        }
    }

    /// A number the carrier did not recognise is still an answer (and still billed).
    func testLookupInvalid() async throws {
        var replies = Self.reads
        replies[Self.lookup] = .fixture("district-number-lookup-invalid")
        try await assertScreen(replies, devices: [.iPhone], locales: [.en]) { container in
            Self.carrierTab(container, role: .client) { model in
                await Self.open(model)
                model.lookupNumber = "+15555550100"
                await model.lookup()
            }
        }
    }

    /// A lookup whose answer was lost: the failure and the sentence that it is not offered again.
    func testLookupUnconfirmed() async throws {
        var replies = Self.reads
        replies[Self.lookup] = .refused(500)
        try await assertScreen(replies, devices: [.iPhone]) { container in
            Self.carrierTab(container, role: .client) { model in
                await Self.open(model)
                model.lookupNumber = "+14165550142"
                await model.lookup()
            }
        }
    }

    /// Turning Verify off adopts the write's own answer: Verify reads off, with its enable action.
    func testVerifyTurnedOff() async throws {
        var replies = Self.reads
        replies["POST \(Self.verify)"] = .fixture("district-verify-disable")
        try await assertScreen(replies, devices: [.iPhone]) { container in
            Self.carrierTab(container, role: .client) { model in
                await Self.open(model)
                await model.setVerify(enabled: false)
            }
        }
    }

    /// A Verify toggle whose answer was lost disarms every carrier write on the tab.
    func testVerifyToggleUnconfirmed() async throws {
        var replies = Self.reads
        replies["POST \(Self.verify)"] = .refused(500)
        try await assertScreen(replies, devices: [.iPhone]) { container in
            Self.carrierTab(container, role: .client) { model in
                await Self.open(model)
                await model.setVerify(enabled: false)
            }
        }
    }

    /// Every form filled in, so each submit control is armed.
    func testFormsFilled() async throws {
        try await assertScreen(Self.reads) { container in
            Self.carrierTab(container, role: .client) { model in
                await Self.open(model)
                Self.fill(model)
            }
        }
    }

    /// An A2P filing the carrier accepted: its status, in the tab's notice.
    func testA2PSubmitted() async throws {
        var replies = Self.reads
        replies["/api/district/workspace/a2p"] = .fixture("district-a2p-registration")
        try await assertScreen(replies, devices: [.iPhone]) { container in
            Self.carrierTab(container, role: .client) { model in
                await Self.open(model)
                Self.fill(model)
                await model.submitA2P()
            }
        }
    }

    /// A toll-free verification the carrier accepted: its status, in the tab's notice.
    func testTollFreeSubmitted() async throws {
        var replies = Self.reads
        replies["/api/district/workspace/tfv"] = .fixture("district-tfv-submission")
        try await assertScreen(replies, devices: [.iPhone]) { container in
            Self.carrierTab(container, role: .client) { model in
                await Self.open(model)
                Self.fill(model)
                await model.submitTollFree()
            }
        }
    }

    /// A new SIP trunk the service created: the form clears and the list is re-read.
    func testSipTrunkCreated() async throws {
        var replies = Self.reads
        replies["POST \(Self.sip)"] = .fixture("district-sip-trunk-create")
        try await assertScreen(replies, devices: [.iPhone], locales: [.en]) { container in
            Self.carrierTab(container, role: .client) { model in
                await Self.open(model)
                Self.fill(model)
                await model.createSipTrunk()
            }
        }
    }

    // MARK: - Helpers

    /// The tab's three panels in the screen's order.
    private static func carrierTab(
        _ container: AppContainer,
        role: WorkspaceRole?,
        drive: @escaping @MainActor @Sendable (NumberProvisioningModel) async -> Void
    ) -> some View {
        ProvisioningHost(container, role: role, drive: drive, content: { model in
            CarrierSection(model: model)
            NumberLookupCard(model: model)
            ComplianceSection(model: model)
        })
    }

    /// The three reads the tab fires on opening, in the screen's order.
    private static func open(_ model: NumberProvisioningModel) async {
        await model.loadCarrier()
        await model.loadVerify()
        await model.loadSip()
    }

    private static func fill(_ model: NumberProvisioningModel) {
        model.sipDraft.name = "Front desk"
        model.sipDraft.domain = "contract-desk.sip.twilio.com"
        model.sipDraft.ipAddresses = "203.0.113.10\n\n198.51.100.0/24"
        model.a2pDraft.businessName = "Contract Clinic"
        model.a2pDraft.website = "https://clinic.contract.test"
        model.a2pDraft.campaignType = "MARKETING"
        model.a2pDraft.campaignDescription = "Appointment reminders for booked patients."
        model.a2pDraft.sampleOne = "Hi Sam, your appointment is Thursday at 2pm."
        model.a2pDraft.sampleTwo = "Reply C to confirm or R to reschedule."
        model.tfvDraft.phoneNumber = "+18005550188"
        model.tfvDraft.businessName = "Contract Clinic"
        model.tfvDraft.optInImageUrl = "https://clinic.contract.test/opt-in.png"
        model.tfvDraft.useCase = "Notifications"
    }
}
