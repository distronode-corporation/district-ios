@testable import DistrictAI
import SwiftUI
import XCTest

/// One call's screen in the states the recorded call can be edited into: a transfer that
/// failed, a missed call with nothing analysed, and a read that was refused.
final class CallScopeSnapshotTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"
    private static let path = "/api/district/calls/call_contract_answered"

    private static func call(_ edit: @escaping (inout [String: Any]) -> Void) -> FixtureTransport.Reply {
        .recorded("district-call-detail") { json in
            json.editObject("call", edit)
        }
    }

    private func draw(
        _ reply: FixtureTransport.Reply,
        devices: [Device] = Device.allCases,
        testName: String = #function
    ) async throws {
        try await assertScreen([Self.path: reply], devices: devices, testName: testName) { container in
            CallDetailView(container: container, workspaceId: Self.workspace, callId: "call_contract_answered")
        }
    }

    /// A transfer to a person that failed on the ring timeout: the transfer card names the
    /// outcome and its reason.
    func testCallDetailTransferFailed() async throws {
        try await draw(Self.call { call in
            call["transferStatus"] = "failed"
            call["transferReason"] = "ring_timeout"
        })
    }

    /// A refused read: the failure with its retry.
    func testCallDetailFailed() async throws {
        try await draw(.refused(500), devices: [.iPhone])
    }

    /// A call deleted elsewhere: no longer available, with no retry.
    func testCallDetailGone() async throws {
        try await draw(.refused(404, "Call not found"), devices: [.iPhone])
    }
}
