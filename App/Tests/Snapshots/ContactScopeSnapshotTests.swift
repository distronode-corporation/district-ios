@testable import DistrictAI
import DistrictData
import SwiftUI
import XCTest

/// One contact's screen in the states its record and its research can be in, and the add
/// sheet, drawn from the service's recorded contact.
final class ContactScopeSnapshotTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"
    private static let detail = "/api/district/contacts/get"

    /// The recorded contact with `edit` applied to the contact object.
    private static func contact(_ edit: @escaping (inout [String: Any]) -> Void) -> FixtureTransport.Reply {
        .recorded("district-contact-detail") { json in
            json.editObject("contact", edit)
        }
    }

    private func drawDetail(
        _ reply: FixtureTransport.Reply,
        role: WorkspaceRole = .client,
        devices: [Device] = Device.allCases,
        testName: String = #function
    ) async throws {
        try await assertScreen([Self.detail: reply], devices: devices, testName: testName) { container in
            ContactDetailView(
                container: container,
                workspaceId: Self.workspace,
                role: role,
                contactId: "contact_contract_1"
            )
        }
    }

    // MARK: - The record

    /// A viewer reads the record and the research with the read-only line in place of
    /// every control.
    func testContactDetailForAViewer() async throws {
        try await drawDetail(.fixture("district-contact-detail"), role: .viewer, devices: [.iPhone])
    }

    /// A contact with no address and no research at all: the "no phone or email" line, no
    /// attribute cards, Research offered and Clear not, and a video call with nowhere to go.
    func testContactDetailBare() async throws {
        try await drawDetail(Self.contact { contact in
            for key in [
                "phoneNumber",
                "email",
                "company",
                "intelligence",
                "dgiStatus",
                "budget",
                "timeline",
                "website",
                "latestContextSummary",
            ] {
                contact[key] = NSNull()
            }
            contact["visualMemory"] = [Any]()
            contact["socialHandles"] = [String: Any]()
        })
    }

    /// Research in progress: the dossier says so, and neither Research nor Clear is offered
    /// twice.
    func testContactDetailResearching() async throws {
        try await drawDetail(Self.contact { contact in
            contact["dgiStatus"] = "crawling"
            contact["intelligence"] = NSNull()
        }, devices: [.iPhone])
    }

    /// Research that failed: the service's reason, and Research offered again.
    func testContactDetailResearchFailed() async throws {
        try await drawDetail(Self.contact { contact in
            contact["dgiStatus"] = "failed"
            contact["dgiError"] = "The website could not be reached"
            contact["intelligence"] = NSNull()
        }, devices: [.iPhone])
    }

    /// Research the service returned as nested structure (the field is free-form JSON):
    /// lists, objects, numbers and booleans each drawn as labelled lines.
    func testContactDetailNestedResearch() async throws {
        try await drawDetail(Self.contact { contact in
            contact["intelligence"] = [
                "executiveSummary": "Regional roofing firm, 40 staff.",
                "keyFacts": ["Family owned", "Two depots"],
                "decisionMakers": [["name": "Ada Lovelace", "role": "Owner"]],
                "funding": ["stage": "Bootstrapped", "employees": 40, "public": false] as [String: Any],
                "score": 0.82,
                "notes": NSNull(),
            ] as [String: Any]
        })
    }

    /// A contact deleted elsewhere: "no longer available", with no retry.
    func testContactDetailGone() async throws {
        try await drawDetail(.refused(404, "Contact not found"), devices: [.iPhone])
    }

    /// A refused read: the failure with its retry.
    func testContactDetailFailed() async throws {
        try await drawDetail(.refused(500), devices: [.iPhone])
    }

    // MARK: - The add sheet

    /// The sheet as it opens: empty boxes and Add disabled.
    func testCreateContactSheet() async throws {
        try await assertScreen { container in
            CreateContactSheet(model: ContactsModel(container: container, workspaceId: Self.workspace, role: .client))
        }
    }

    /// The service refused the create (a duplicate number): its sentence under the form.
    ///
    /// ⚠️ THE BOXES DRAW EMPTY because what was typed is the sheet's own view state; the
    /// failure line is the model's, and that is what this pins.
    func testCreateContactSheetRefused() async throws {
        try await assertScreen(
            ["POST /api/district/contacts/create": .refused(409, "A contact with this phone number already exists")],
            devices: [.iPhone]
        ) { container in
            let model = ContactsModel(container: container, workspaceId: Self.workspace, role: .client)
            return CreateContactSheet(model: model)
                .task { await model.create(name: "Ada", phoneNumber: "+14165551234", email: "") }
        }
    }

    // MARK: - Blocking

    /// A block the service refused: the control stays on Block, and the failure is said
    /// under it with Dismiss; the badge beside it is the one a blocked contact wears.
    func testBlockRefused() async throws {
        try await assertScreen(
            ["POST /api/district/contacts/block": .refused(500)],
            devices: [.iPhone]
        ) { container in
            let store = container.blockedContacts
            return VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                BlockedBadge(identifier: "snapshot-badge")
                ContactBlockControl(
                    workspaceId: Self.workspace,
                    subject: .contact("contact_contract_2"),
                    blocked: false,
                    busy: false,
                    store: store
                )
                BlockFailureNotice(store: store)
            }
            .padding()
            .task {
                _ = await store.setBlocked(
                    workspaceId: Self.workspace,
                    subject: .contact("contact_contract_2"),
                    blocked: true
                )
            }
        }
    }
}
