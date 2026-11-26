@testable import DistrictAI
import DistrictL10n
import DistrictModel
import SwiftUI
import XCTest

/// The Inbox list in the states the recorded conversations do not show by themselves, and
/// the message search rows.
///
/// ⚠️ SEARCH IS DRIVEN BY THE SCREEN'S OWN `.searchable` TEXT, which a test cannot type into,
/// so the result rows are drawn directly from a decoded ``MessageSearchResponse``.
final class InboxScopeSnapshotTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"

    private func drawInbox(
        _ replies: [String: FixtureTransport.Reply],
        role: WorkspaceRole? = .client,
        locales: [L10nLocale] = [.en, .frCA],
        testName: String = #function
    ) async throws {
        try await assertScreen(replies, devices: [.iPhone], locales: locales, testName: testName) { container in
            InboxView(
                container: container,
                workspaceId: Self.workspace,
                role: role,
                path: .constant([]),
                pushSignal: 0,
                selection: nil
            )
        }
    }

    private static func conversations(_ edit: (inout [String: Any]) -> Void) -> FixtureTransport.Reply {
        .recorded("district-conversations", with: edit)
    }

    /// No conversations yet: the empty sentence, and the compose button still offered.
    func testInboxEmpty() async throws {
        let none = Self.conversations { $0["conversations"] = [Any]() }
        try await drawInbox(["/api/district/conversations": none])
    }

    /// A refused read draws the failure with its retry.
    func testInboxFailed() async throws {
        try await drawInbox(["/api/district/conversations": .refused(500)], locales: [.en])
    }

    /// A viewer reads the list with no compose and no mark-all-read.
    func testInboxForAViewer() async throws {
        try await drawInbox([:], role: .viewer, locales: [.en])
    }

    /// The scan window was exhausted: the list is honest but short, and the caption says so.
    func testInboxPartialScan() async throws {
        let partial = Self.conversations { json in
            json["scanned"] = json["scanLimit"] ?? 500
        }
        try await drawInbox(["/api/district/conversations": partial])
    }

    /// Everything read: no unread badges and no mark-all-read button.
    func testInboxAllRead() async throws {
        let read = Self.conversations { json in
            json.editEach("conversations") { $0["unreadCount"] = 0 }
        }
        try await drawInbox(["/api/district/conversations": read], locales: [.en])
    }

    /// One thread is mine and one a teammate's: the assignee badges.
    func testInboxAssigned() async throws {
        let assigned = Self.conversations { json in
            json.editEach("conversations") { row in
                if row["threadKey"] as? String == "contact:contact_contract_1" {
                    row["assigneeEmail"] = "founder@contract.test"
                    row["assignedToMe"] = true
                } else {
                    row["assigneeEmail"] = "operator@contract.test"
                    row["assignedToMe"] = false
                }
            }
        }
        try await drawInbox(["/api/district/conversations": assigned])
    }

    // MARK: - Search rows

    /// A hit from a named contact with a subject, an outbound hit to a bare number, and a hit
    /// whose contact name is blank (it falls back to the address).
    private static let searchBody = #"""
    {"success":true,"limit":50,"results":[
     {"messageId":"msg_search_email","key":"ada@contract.test","threadKey":"contact:contact_contract_1",
      "counterpart":"ada@contract.test","kind":"email","contactId":"contact_contract_1",
      "contactName":"Contract Test Caller","contactEmail":"ada@contract.test",
      "body":"Following up by email, could we move Thursday to Friday?","subject":"Re: Thursday appointment",
      "direction":"inbound","type":"email","createdAt":"2026-08-15T14:20:00.000Z"},
     {"messageId":"msg_search_sms","key":"14165558888","threadKey":"addr:14165558888",
      "counterpart":"+14165558888","kind":"phone","contactId":null,"contactName":null,"contactEmail":null,
      "body":"Following up on your quote.\nIt is valid until Friday.","subject":null,
      "direction":"outbound","type":"sms","createdAt":"2026-08-15T09:00:00.000Z"},
     {"messageId":"msg_search_blank","key":"14165557777","threadKey":"addr:14165557777",
      "counterpart":"+14165557777","kind":"phone","contactId":"contact_blank","contactName":"   ",
      "contactEmail":null,"body":"Thursday works.","subject":"  ","direction":"inbound","type":"sms",
      "createdAt":"2026-08-14T18:45:00.000Z"}]}
    """#

    func testMessageSearchRows() async throws {
        let hits = try JSONDecoder().decode(MessageSearchResponse.self, from: Data(Self.searchBody.utf8)).results
        XCTAssertEqual(hits.count, 3)
        try await assertScreen(devices: [.iPhone]) { _ in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(hits, id: \.messageId) { hit in
                        MessageSearchRow(hit: hit)
                        DistrictRowDivider()
                    }
                }
            }
        }
    }
}
