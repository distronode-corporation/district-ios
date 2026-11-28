@testable import DistrictAI
import DistrictData
import SwiftUI
import XCTest

/// The support list, one request's thread, and the report sheet, in the states the
/// service's recorded answers (and its refusals) leave them in.
final class SupportSnapshotTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"
    private static let requests = "/api/district/support/requests"
    private static let filed = "/api/district/support/requests/support_filed"

    // MARK: - The list

    /// A viewer sees the recorded requests without the New request button.
    func testSupportForAViewer() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            SupportView(container: container, workspaceId: Self.workspace, role: .viewer)
        }
    }

    /// No requests yet: the empty sentence under the action bar.
    func testSupportEmpty() async throws {
        try await assertScreen([Self.requests: .json(#"{"success":true,"requests":[]}"#)]) { container in
            SupportView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    /// A refused list read: the failure card with its retry, not an empty list.
    func testSupportListFailed() async throws {
        try await assertScreen([Self.requests: .refused(500)]) { container in
            SupportView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    // MARK: - One request

    /// A viewer reads the thread but has no reply box and no Close.
    func testSupportThreadForAViewer() async throws {
        try await assertScreen([Self.filed: .fixture("district-support-request")], devices: [.iPhone]) { container in
            SupportThreadView(container: container, workspaceId: Self.workspace, role: .viewer, key: "support_filed")
        }
    }

    /// A request the desk has not filed yet: no issue key, no messages, nothing to reply on.
    func testSupportThreadNotYetFiled() async throws {
        let pending = FixtureTransport.Reply.recorded("district-support-request") { json in
            json.editObject("request") { request in
                request["issueKey"] = NSNull()
                request["id"] = "support_pending"
                request["statusName"] = "Opening"
                request["statusCategory"] = "PENDING"
                request["filed"] = false
                request["closeable"] = false
                request["messages"] = [Any]()
            }
        }
        try await assertScreen(["\(Self.requests)/support_pending": pending]) { container in
            SupportThreadView(container: container, workspaceId: Self.workspace, role: .client, key: "support_pending")
        }
    }

    /// A request the desk resolved: the Done badge, and no Close.
    func testSupportThreadResolved() async throws {
        let done = FixtureTransport.Reply.recorded("district-support-request") { json in
            json.editObject("request") { request in
                request["statusName"] = "Done"
                request["statusCategory"] = "DONE"
                request["closeable"] = false
            }
        }
        try await assertScreen([Self.filed: done], devices: [.iPhone]) { container in
            SupportThreadView(container: container, workspaceId: Self.workspace, role: .client, key: "support_filed")
        }
    }

    /// A refused thread read: the failure with its retry.
    func testSupportThreadFailed() async throws {
        try await assertScreen([Self.filed: .refused(500)], devices: [.iPhone]) { container in
            SupportThreadView(container: container, workspaceId: Self.workspace, role: .client, key: "support_filed")
        }
    }

    // MARK: - The report sheet

    /// Reporting a conversation whose counterpart has a name: the headline names them.
    func testReportConversation() async throws {
        try await assertScreen { container in
            ReportSheet(
                container: container,
                workspaceId: Self.workspace,
                target: .conversation(threadKey: "contact:contact_contract_1", name: "Contract Test Caller")
            )
        }
    }

    /// A conversation with no resolved name falls back to the neutral headline.
    func testReportUnnamedConversation() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            ReportSheet(
                container: container,
                workspaceId: Self.workspace,
                target: .conversation(threadKey: "addr:14165558888", name: nil)
            )
        }
    }

    /// Reporting a call.
    func testReportCall() async throws {
        try await assertScreen(devices: [.iPhone]) { container in
            ReportSheet(
                container: container,
                workspaceId: Self.workspace,
                target: .call(callId: "call_contract_answered")
            )
        }
    }

    // MARK: - The write notice

    /// The three ways a write can end, as the list and the thread say them: a filing
    /// confirmed (dismissable), a failure that may be repeated (dismissable), and a failure
    /// that must not be (no Dismiss, and the line saying why).
    func testSupportWriteNotices() async throws {
        let failure = FailureText(message: "The support desk is unavailable right now.", action: .retry)
        try await assertScreen(devices: [.iPhone]) { _ in
            VStack(spacing: DistrictSpacing.section) {
                SupportWriteNotice(state: .done(SupportCopy.filed), onDismiss: {})
                SupportWriteNotice(state: .failed(failure, .allowed), onDismiss: {})
                SupportWriteNotice(state: .failed(failure, .refused), onDismiss: {})
                SupportWriteNotice(state: .idle, onDismiss: {})
            }
            .padding()
        }
    }
}
