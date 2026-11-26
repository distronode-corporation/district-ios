@testable import DistrictAI
import Foundation
import SwiftUI
import XCTest

/// The setup wizard on each of its steps and in each of its endings, drawn from the service's
/// recorded `district-setup-patch.json` with the step states a test names, so the wizard opens
/// on the first step still `todo` (``SetupFlow/firstOpen(_:)``) as it does for a real owner.
final class SetupStepSnapshotTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"
    private static let setupPath = "/api/district/setup"
    private static let order = ["business", "number", "receptionist", "callers", "calls", "golive"]

    /// The recorded setup state with every step before `open` done and the rest `todo`, and
    /// `completedAt` stamped when `finished`.
    private static func setup(
        open: String?,
        fixture: String = "district-setup-patch",
        finished: Bool = false
    ) -> FixtureTransport.Reply {
        let recorded = FixtureTransport.fixtureData(fixture)
        guard var json = (try? JSONSerialization.jsonObject(with: recorded)) as? [String: Any],
              var progress = json["setupProgress"] as? [String: Any]
        else {
            XCTFail("\(fixture).json is not the setup shape")
            return .json("{}")
        }
        let openIndex = open.flatMap { order.firstIndex(of: $0) } ?? order.count
        var steps: [String: String] = [:]
        for (index, key) in order.enumerated() {
            steps[key] = index < openIndex ? "done" : "todo"
        }
        progress["steps"] = steps
        if finished {
            progress["completedAt"] = "2026-11-08T12:00:00.000Z"
        }
        json["setupProgress"] = progress
        guard let body = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else {
            XCTFail("the setup state could not be written back")
            return .json("{}")
        }
        return FixtureTransport.Reply(status: 200, body: body)
    }

    private func assertWizard(
        _ replies: [String: FixtureTransport.Reply],
        testName: String = #function,
        line: UInt = #line
    ) async throws {
        try await assertScreen(replies, testName: testName, line: line) { container in
            SetupWizardView(container: container, workspaceId: Self.workspace, workspaceName: "Contract Clinic") {}
        }
    }

    // MARK: - The steps

    /// Step 1 with the facts the service holds: name, website, language and the services read so far.
    func testBusinessStep() async throws {
        try await assertWizard([Self.setupPath: Self.setup(open: "business")])
    }

    /// Step 1 for a workspace that has told the service nothing yet.
    func testBusinessStepNoFacts() async throws {
        try await assertWizard([Self.setupPath: Self.setup(open: "business", fixture: "district-setup")])
    }

    /// Step 2: the number held, and buying another opened on the web.
    func testNumberStep() async throws {
        try await assertWizard([Self.setupPath: Self.setup(open: "number")])
    }

    /// Step 4 with the recorded address and hours filled in.
    func testCallersStep() async throws {
        try await assertWizard([Self.setupPath: Self.setup(open: "callers")])
    }

    /// Step 4 with no business facts: every field empty, no hours.
    func testCallersStepEmpty() async throws {
        try await assertWizard([Self.setupPath: Self.setup(open: "callers", fixture: "district-setup")])
    }

    /// Step 5: how calls are answered (the recorded call handling), the transfer number from
    /// the config and the calendar from the connections.
    func testCallsStep() async throws {
        try await assertWizard([Self.setupPath: Self.setup(open: "calls")])
    }

    /// Step 5 when the call-handling read is refused: a retry, never a form of defaults.
    func testCallsStepFailed() async throws {
        try await assertWizard([
            Self.setupPath: Self.setup(open: "calls"),
            "/api/district/workspace/call-handling": .json(#"{"error":"Something went wrong."}"#, status: 500),
        ])
    }

    /// Step 6: the test call and the recorded forwarding check, passed.
    func testGoLiveStep() async throws {
        try await assertWizard([
            Self.setupPath: Self.setup(open: "golive"),
            "/api/district/setup/forwarding-check": .fixture("district-forwarding-check"),
        ])
    }

    /// Step 6 for a workspace that has never run the forwarding check.
    func testGoLiveStepNoCheck() async throws {
        try await assertWizard([
            Self.setupPath: Self.setup(open: "golive"),
            "/api/district/setup/forwarding-check": .json(
                #"{"available":true,"forwardingCheck":null,"attemptsLeft":4}"#
            ),
        ])
    }

    // MARK: - The endings

    /// Every step done and `completedAt` stamped.
    func testFinished() async throws {
        try await assertWizard([Self.setupPath: Self.setup(open: nil, finished: true)])
    }

    /// A member who is not the owner (403).
    func testRefusedNotOwner() async throws {
        try await assertWizard([Self.setupPath: .json(#"{"error":"Only the owner can do this."}"#, status: 403)])
    }

    /// A workspace the wizard is not offered for (409 `setup_not_available`).
    func testRefusedNotAvailable() async throws {
        try await assertWizard([
            Self.setupPath: .json(#"{"error":"No.","code":"setup_not_available"}"#, status: 409),
        ])
    }

    /// A read that fails for another reason: the failure and its retry.
    func testFailed() async throws {
        try await assertWizard([Self.setupPath: .json(#"{"error":"Something went wrong."}"#, status: 500)])
    }
}
