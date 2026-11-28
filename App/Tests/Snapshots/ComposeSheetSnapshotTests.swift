@testable import DistrictAI
import DistrictData
import DistrictL10n
import DistrictModel
import SwiftUI
import XCTest

/// The New message sheet, over a ``ComposeModel`` the test holds and drives the way the
/// sheet's rows would (choose a contact, type an address), from the recorded contacts.
///
/// ⚠️ THE SHEET'S OWN `prepare()` RESETS THE RECIPIENT, so a drive waits for the contacts it
/// reads to land before choosing; choosing first would be wiped by that reset.
///
/// ⚠️ THE MESSAGE AND SUBJECT BOXES ARE THE SHEET'S PRIVATE STATE, so they are drawn empty in
/// every state here; the refused send is the model's real failure, sent with a body of its own.
final class ComposeSheetSnapshotTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"

    private func drawCompose(
        _ replies: [String: FixtureTransport.Reply] = [:],
        role: WorkspaceRole? = .client,
        devices: [Device] = [.iPhone],
        locales: [L10nLocale] = [.en, .frCA],
        testName: String = #function,
        drive: @escaping @MainActor @Sendable (ComposeModel) async -> Void = { _ in }
    ) async throws {
        try await assertScreen(replies, devices: devices, locales: locales, testName: testName) { container in
            let model = ComposeModel(container: container, workspaceId: Self.workspace, role: role)
            return ComposeSheet(model: model, onSent: { _ in })
                .task {
                    await Self.untilContactsRead(model)
                    await drive(model)
                }
        }
    }

    /// Waits (bounded) for the sheet's own contacts read to answer, either way.
    private static func untilContactsRead(_ model: ComposeModel) async {
        for _ in 0 ..< 300 {
            if case .loading = model.contactsState {
                try? await Task.sleep(for: .milliseconds(10))
            } else {
                return
            }
        }
    }

    private static func contact(_ model: ComposeModel, _ id: String) -> Contact? {
        let found = model.contacts.first { $0.id == id }
        XCTAssertNotNil(found, "no recorded contact \(id)")
        return found
    }

    /// The recorded contacts as suggestions under the To box, with the recency caption.
    func testComposeSuggestions() async throws {
        try await drawCompose(devices: Device.allCases)
    }

    /// A query filters the suggestions and offers the typed address as its own row.
    func testComposeFiltered() async throws {
        try await drawCompose(locales: [.en]) { model in
            model.query = "sparse"
        }
    }

    /// The contacts read failed: a quiet caption, and a typed address still works.
    func testComposeSuggestionsFailed() async throws {
        try await drawCompose(["/api/district/contacts": .refused(500)]) { model in
            model.query = "+14165550000"
        }
    }

    /// A contact with a phone and an email: the channel picker on SMS, and the message box.
    func testComposeContactWithTwoChannels() async throws {
        try await drawCompose { model in
            if let contact = Self.contact(model, "contact_contract_1") {
                model.choose(contact)
            }
        }
    }

    /// The same contact on email: the subject box appears above the message.
    func testComposeContactOnEmail() async throws {
        try await drawCompose(locales: [.en]) { model in
            if let contact = Self.contact(model, "contact_contract_1") {
                model.choose(contact)
                model.selectChannel(1)
            }
        }
    }

    /// An email-only contact: one channel, shown as a badge rather than a picker.
    func testComposeEmailOnlyContact() async throws {
        try await drawCompose(locales: [.en]) { model in
            if let contact = Self.contact(model, "contact_contract_2") {
                model.choose(contact)
            }
        }
    }

    /// A contact with no reachable address: said in red, and no message box to type into.
    func testComposeContactWithNoAddress() async throws {
        let bare: FixtureTransport.Reply = .recorded("district-contacts") { json in
            json.editEach("contacts") { row in
                if row["id"] as? String == "contact_contract_2" {
                    row["email"] = NSNull()
                }
            }
        }
        try await drawCompose(["/api/district/contacts": bare]) { model in
            if let contact = Self.contact(model, "contact_contract_2") {
                model.choose(contact)
            }
        }
    }

    /// A typed number goes out on SMS.
    func testComposeTypedAddress() async throws {
        try await drawCompose(locales: [.en]) { model in
            model.query = " +14165550000 "
            model.useTypedAddress()
        }
    }

    /// The service refused the send: the reason under the boxes, the recipient kept.
    func testComposeSendRefused() async throws {
        let replies: [String: FixtureTransport.Reply] = [
            "POST /api/district/messages/send": .refused(502, "The carrier did not accept the message."),
        ]
        try await drawCompose(replies) { model in
            model.query = "+14165550000"
            model.useTypedAddress()
            _ = await model.send(body: "Thursday at 2pm works.", subject: "")
        }
    }

    /// A viewer sees the sheet with Send disabled whatever is typed.
    func testComposeForAViewer() async throws {
        try await drawCompose(role: .viewer, locales: [.en]) { model in
            model.query = "+14165550000"
            model.useTypedAddress()
        }
    }
}
