@testable import DistrictAI
import DistrictModel
import SwiftUI
import XCTest

/// The Registrations tab of Phone numbers: the start form, a country's published requirements,
/// and the workspace's own filings in their draft, in-review and rejected states.
///
/// ⚠️ THE SERVICE RECORDS NO FIXTURE FOR THE FILING ROUTES, so their bodies are stated in
/// ``MarketplaceBodies`` in the shape district-core-swift's `NumberProvisioningBodies` holds the
/// models to (the route source, quoted on each type in `NumberProvisioningResponses.swift`).
final class MarketplaceRegistrationsSnapshotTests: ScreenSnapshotTestCase {
    private static let registrations = "/api/district/workspace/numbers/registrations"
    private static let requirements = "/api/district/workspace/numbers/requirements"
    private static let submit = "/api/district/workspace/numbers/registrations/submit"

    /// A draft with two documents (one not yet stored), a filing in review and a rejected
    /// one with its carrier's reasons, under both country gates.
    func testRegistrationsLoaded() async throws {
        try await assertScreen([Self.registrations: .json(MarketplaceBodies.registrationsMixed)]) { container in
            Self.section(container, role: .client) { await $0.loadRegistrations() }
        }
    }

    /// No filings yet: the empty sentence, and the countries a number sells in without one.
    func testRegistrationsEmpty() async throws {
        try await assertScreen([Self.registrations: .json(MarketplaceBodies.registrationsEmpty)]) { container in
            Self.section(container, role: .client) { await $0.loadRegistrations() }
        }
    }

    /// A viewer is told who can file, and the role-gated read is never sent (the transport
    /// would record it as unanswered).
    func testRegistrationsForAViewer() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            Self.section(container, role: .viewer) { await $0.loadRegistrations() }
        }
    }

    /// A refused read draws its failure card with a retry, not an empty list.
    func testRegistrationsFailed() async throws {
        try await assertScreen([Self.registrations: .refused(500)], devices: [.iPhone]) { container in
            Self.section(container, role: .client) { await $0.loadRegistrations() }
        }
    }

    /// A country's published rules, one field and one document, for a country not yet sellable.
    func testRequirementsPublished() async throws {
        try await assertScreen([
            Self.registrations: .json(MarketplaceBodies.registrationsEmpty),
            Self.requirements: .json(MarketplaceBodies.requirementsEstonia),
        ]) { container in
            Self.section(container, role: .client) { model in
                model.registrationDraft.country = " ee "
                model.registrationDraft.friendlyName = "Contoso OÜ"
                await model.loadRequirements()
                await model.loadRegistrations()
            }
        }
    }

    /// A country that publishes nothing for the type: no registration is required, which is
    /// an answer rather than a failed lookup.
    func testRequirementsNoneRequired() async throws {
        try await assertScreen([
            Self.registrations: .json(MarketplaceBodies.registrationsEmpty),
            Self.requirements: .json(MarketplaceBodies.requirementsNone),
        ]) { container in
            Self.section(container, role: .client) { model in
                model.registrationDraft.country = "CA"
                await model.loadRequirements()
                await model.loadRegistrations()
            }
        }
    }

    /// A requirements lookup the service refused, with its retry.
    func testRequirementsFailed() async throws {
        try await assertScreen(
            [
                Self.registrations: .json(MarketplaceBodies.registrationsEmpty),
                Self.requirements: .refused(500),
            ],
            devices: [.iPhone]
        ) { container in
            Self.section(container, role: .client) { model in
                model.registrationDraft.country = "EE"
                await model.loadRequirements()
                await model.loadRegistrations()
            }
        }
    }

    /// A submit the carrier accepted: the "filed" notice over the re-read list.
    func testSubmitFiled() async throws {
        try await assertScreen(
            [
                Self.registrations: .json(MarketplaceBodies.registrationsMixed),
                Self.submit: .json(MarketplaceBodies.submitted),
            ],
            devices: [.iPhone]
        ) { container in
            Self.section(container, role: .client) { model in
                await model.loadRegistrations()
                await model.submitRegistration(bundleId: "bun_draft")
            }
        }
    }

    /// A submit whose answer was lost (a 502): the failure, the sentence saying it will not be
    /// offered again, and the draft's controls disabled.
    func testSubmitUnconfirmed() async throws {
        try await assertScreen(
            [
                Self.registrations: .json(MarketplaceBodies.registrationsMixed),
                Self.submit: .refused(502, "Bad gateway"),
            ],
            devices: [.iPhone]
        ) { container in
            Self.section(container, role: .client) { model in
                await model.loadRegistrations()
                await model.submitRegistration(bundleId: "bun_draft")
            }
        }
    }

    /// A 422 says the carrier refused and points at the list, where its objections are; the
    /// controls stay armed because a 4xx proves nothing was filed.
    func testSubmitRefusedByTheCarrier() async throws {
        try await assertScreen(
            [
                Self.registrations: .json(MarketplaceBodies.registrationsMixed),
                Self.submit: .refused(422, "The registry extract is unreadable."),
            ],
            devices: [.iPhone]
        ) { container in
            Self.section(container, role: .client) { model in
                await model.loadRegistrations()
                await model.submitRegistration(bundleId: "bun_draft")
            }
        }
    }

    // MARK: - Helpers

    /// The tab as the screen draws it, over a model `drive` has read (and written) through.
    private static func section(
        _ container: AppContainer,
        role: WorkspaceRole?,
        drive: @escaping @MainActor @Sendable (NumberProvisioningModel) async -> Void
    ) -> some View {
        ProvisioningHost(container, role: role, drive: drive, content: { RegistrationsSection(model: $0) })
    }
}

/// A provisioning surface over its own ``NumberProvisioningModel``, drawn as the Phone numbers
/// screen draws it, with `drive` run against the model once it is on screen (the reads its tab
/// fires, and any write the state needs).
///
/// ⚠️ THE MODEL IS BUILT FROM THE DRAWING'S OWN CONTAINER, so every request it sends reaches
/// that drawing's ``FixtureTransport`` and is held to its `unanswered` check.
struct ProvisioningHost<Content: View>: View {
    @State private var model: NumberProvisioningModel
    private let drive: @MainActor @Sendable (NumberProvisioningModel) async -> Void
    private let content: (NumberProvisioningModel) -> Content

    init(
        _ container: AppContainer,
        role: WorkspaceRole?,
        drive: @escaping @MainActor @Sendable (NumberProvisioningModel) async -> Void,
        @ViewBuilder content: @escaping (NumberProvisioningModel) -> Content
    ) {
        _model = State(initialValue: NumberProvisioningModel(
            container: container,
            workspaceId: MarketplaceBodies.workspace,
            role: role
        ))
        self.drive = drive
        self.content = content
    }

    var body: some View {
        let hosted = model
        let run = drive
        return ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                content(hosted)
            }
            .padding(DistrictSpacing.gutter)
        }
        .task { await run(hosted) }
    }
}

/// The bodies of the provisioning routes the service records no fixture for.
enum MarketplaceBodies {
    static let workspace = "ws-contract-test"

    private static let draftRow = #"""
    {"id":"bun_draft","isoCountry":"EE","numberType":"local","endUserType":"business",
     "friendlyName":"Contoso OÜ","status":"draft","rejectionReasons":[],"submittedAt":null,
     "reviewedAt":null,"createdAt":"2026-09-07T09:41:00.000Z",
     "documents":[{"id":"doc_1","requirementName":"business_registration_number_info",
                   "mimeType":"application/pdf","sizeBytes":2048,"stored":true,
                   "submitted":false,"updatedAt":"2026-09-07T09:42:00.000Z"},
                  {"id":"doc_2","requirementName":"proof_of_address",
                   "mimeType":"image/jpeg","sizeBytes":4096,"stored":false,
                   "submitted":false,"updatedAt":"2026-09-07T09:43:00.000Z"}]}
    """#

    private static let reviewRow = #"""
    {"id":"bun_review","isoCountry":"GB","numberType":"mobile","endUserType":"business",
     "friendlyName":null,"status":"in-review","rejectionReasons":[],
     "submittedAt":"2026-09-05T09:41:00.000Z","reviewedAt":null,
     "createdAt":"2026-09-04T09:41:00.000Z","documents":[]}
    """#

    private static let rejectedRow = #"""
    {"id":"bun_rejected","isoCountry":"DE","numberType":"local","endUserType":"business",
     "friendlyName":"Contoso GmbH","status":"twilio-rejected",
     "rejectionReasons":["The registry extract is unreadable.","The address does not match the extract."],
     "submittedAt":"2026-09-05T09:41:00.000Z","reviewedAt":"2026-09-06T11:02:00.000Z",
     "createdAt":"2026-09-04T09:41:00.000Z",
     "documents":[{"id":"doc_9","requirementName":"business_registration_number_info",
                   "mimeType":"application/pdf","sizeBytes":2048,"stored":true,
                   "submitted":true,"updatedAt":"2026-09-05T09:40:00.000Z"}]}
    """#

    static let registrationsMixed = """
    {"success":true,"registrations":[\(draftRow),\(reviewRow),\(rejectedRow)],
     "approvedCountries":["FR"],"platformCountries":["US","CA"]}
    """

    static let registrationsEmpty = #"""
    {"success":true,"registrations":[],"approvedCountries":[],"platformCountries":["US","CA"]}
    """#

    static let requirementsEstonia = #"""
    {"success":true,"country":"EE","numberType":"local","purchasable":false,
     "requirements":{"isoCountry":"EE","numberType":"local","endUserType":"business",
                     "regulationSid":"RN1","friendlyName":"Estonia local business",
                     "requirements":[
                       {"kind":"end_user","name":"Business","requirementName":"business_info",
                        "type":"business","fields":["business_name","business_registration_number"]},
                       {"kind":"supporting_document","name":"Registry extract",
                        "requirementName":"business_registration_number_info",
                        "type":"document","fields":["business_registration_number"],
                        "acceptedDocuments":[{"name":"Extract","type":"registry_extract",
                                              "fields":["business_registration_number"]}]}]}}
    """#

    static let requirementsNone = #"""
    {"success":true,"country":"CA","numberType":"local","purchasable":true,"requirements":null}
    """#

    static let submitted = #"""
    {"success":true,"registration":{"id":"bun_draft","status":"pending-review",
     "submittedAt":"2026-09-07T10:00:00.000Z"}}
    """#
}
