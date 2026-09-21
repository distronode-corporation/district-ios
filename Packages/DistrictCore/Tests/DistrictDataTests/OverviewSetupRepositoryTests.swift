import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// When the overview offers the owner the rest of setup.
///
/// ⛔ ONE YES AND FIVE NOS, AND EVERY NO IS A DIFFERENT REASON. Only the owner of a
/// workspace that is in the wizard and has not finished it is offered the card. Not the
/// owner (403), a workspace from before the wizard (null progress), a finished wizard, a
/// dropped connection and an undecodable body all answer false, and none of them may
/// surface as an error on the screen. Mirrors Android's `SetupRepositoryTest`.
final class OverviewSetupRepositoryTests: XCTestCase {
    private func repository(_ transport: RepositoryTransport) -> OverviewRepository {
        OverviewRepository(client: .repositoryTest(transport))
    }

    private static let midWizard = #"""
    {"setupProgress":{"steps":{"business":"done","number":"todo","receptionist":"todo",
    "callers":"todo","calls":"todo","golive":"todo"},"paidAt":"2026-09-23T15:04:05.000Z"},
    "businessFacts":null,"region":"ca","tier":"VoicePro","includedNumbers":3,"numbersHeld":1}
    """#

    func testTheOwnerMidWizardIsOfferedTheRestAndTheRightURLIsAsked() async {
        let transport = RepositoryTransport(json: Self.midWizard)

        let needs = await repository(transport).needsWebSetup(workspaceId: "ws_owner")

        XCTAssertTrue(needs)
        XCTAssertEqual(transport.requests.first?.method, .get)
        XCTAssertEqual(
            transport.requestedURLs,
            ["https://www.distronode.com/api/district/setup?workspaceId=ws_owner"]
        )
    }

    /// ⛔ THE ORDINARY ANSWER FOR MOST PEOPLE WHO OPEN THE OVERVIEW, not an error.
    func testAMemberIsRefusedByTheServerAndShownNothing() async {
        let transport = RepositoryTransport(
            json: #"{"error":"Only the workspace owner can set up this workspace."}"#,
            status: 403
        )

        let raw = await repository(transport).districtSetup(workspaceId: "ws_member")
        guard case .failure(.http(status: 403, _)) = raw else {
            return XCTFail("a member's read must arrive as the 403 it is, got \(raw)")
        }
        let needs = await repository(RepositoryTransport(
            json: #"{"error":"Only the workspace owner can set up this workspace."}"#,
            status: 403
        )).needsWebSetup(workspaceId: "ws_member")
        XCTAssertFalse(needs)
    }

    func testAWorkspaceFromBeforeTheWizardIsShownNothing() async {
        let transport = RepositoryTransport(
            json: #"{"setupProgress":null,"businessFacts":null,"region":"us","tier":"Pro","numbersHeld":2}"#
        )

        let needs = await repository(transport).needsWebSetup(workspaceId: "ws_old")

        XCTAssertFalse(needs)
    }

    func testAFinishedWizardIsShownNothing() async {
        let transport = RepositoryTransport(
            json: #"{"setupProgress":{"completedAt":"2026-09-24T09:00:00.000Z"}}"#
        )

        let needs = await repository(transport).needsWebSetup(workspaceId: "ws_done")

        XCTAssertFalse(needs)
    }

    /// ⛔ AN ABSENT KEY IS NOT A DECODE FAILURE. Every field is optional so that a key the
    /// server stops sending cannot take the one bit the card needs with it.
    func testABodyMissingEveryOtherKeyStillAnswers() async {
        let transport = RepositoryTransport(json: #"{"setupProgress":{}}"#)

        let needs = await repository(transport).needsWebSetup(workspaceId: "ws_sparse")

        XCTAssertTrue(needs, "progress present with no completedAt is mid-wizard")
    }

    func testANetworkFailureIsShownNothingRatherThanAnError() async {
        let client = ApiClient(
            baseURL: ApiClient.productionBaseURL,
            transport: OfflineSetupTransport(),
            accessToken: { "session-token" }
        )

        let needs = await OverviewRepository(client: client).needsWebSetup(workspaceId: "ws_offline")

        XCTAssertFalse(needs)
    }

    func testAnUndecodableBodyIsShownNothingRatherThanAnError() async {
        let transport = RepositoryTransport(json: #"{"setupProgress":"not an object"}"#)

        let raw = await repository(transport).districtSetup(workspaceId: "ws_drift")
        guard case .failure(.decoding) = raw else {
            return XCTFail("a reshaped body must be a decode failure, got \(raw)")
        }
        let needs = await repository(RepositoryTransport(json: #"{"setupProgress":"not an object"}"#))
            .needsWebSetup(workspaceId: "ws_drift")
        XCTAssertFalse(needs)
    }
}

private struct OfflineSetupTransport: HTTPTransport {
    private struct Offline: Error {}

    func send(_ request: HTTPRequest, followRedirects: Bool) async throws -> HTTPResponse {
        _ = request
        _ = followRedirects
        throw Offline()
    }
}
