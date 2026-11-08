@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The Integrations screen's read: the two calendar rows, which one the receptionist books
/// into, and the page the sheet opens.
///
/// ⛔ THE REAL REPOSITORY OVER A CANNED TRANSPORT, with the bodies of
/// `district-connections.json` and `district-connections-viewer.json`, so the rows come from
/// the bytes the service sends.
@MainActor
final class IntegrationsModelTests: XCTestCase {
    private static let owner = """
    {"connections":[{"provider":"google-calendar","status":"active"},\
    {"provider":"microsoft-calendar","status":"error"},{"provider":"azure-ad","status":"active"}],\
    "calendar":{"activeProvider":"google","source":"preference-unavailable-fallback"}}
    """

    private static let viewer = """
    {"connections":[{"provider":"google-calendar","status":"active"},\
    {"provider":"microsoft-calendar","status":"error"},{"provider":"azure-ad","status":"active"}]}
    """

    private func model(_ transport: SettingsTransport) -> IntegrationsModel {
        IntegrationsModel(
            repository: SetupWizardRepository(client: ApiClient(
                baseURL: ApiClient.productionBaseURL,
                transport: transport,
                accessToken: { "session-token" }
            )),
            workspaceId: "ws_1"
        )
    }

    private func rows(_ model: IntegrationsModel) -> [IntegrationsCalendarRow]? {
        if case let .ready(rows) = model.state {
            return rows
        }
        return nil
    }

    func testTheOwnersReadShowsBothCalendarsAndMarksTheOneBookedInto() async {
        let transport = SettingsTransport([Self.owner])
        let model = model(transport)
        await model.load()

        XCTAssertEqual(transport.paths, ["/api/district/connections"])
        XCTAssertEqual(transport.requests.first?.url.query, "workspaceId=ws_1")
        XCTAssertEqual(rows(model), [
            IntegrationsCalendarRow(provider: .google, status: .active, isActiveProvider: true),
            IntegrationsCalendarRow(provider: .microsoft, status: .error, isActiveProvider: false),
        ])
    }

    /// ⚠️ A VIEWER'S ANSWER HAS NO `calendar` BLOCK, so nothing is marked active, and the
    /// sign-in identity (`azure-ad`) is never drawn as a calendar.
    func testAViewersReadMarksNoCalendarActive() async {
        let model = model(SettingsTransport([Self.viewer]))
        await model.load()

        XCTAssertEqual(rows(model)?.map(\.isActiveProvider), [false, false])
        XCTAssertEqual(rows(model)?.map(\.provider), [.google, .microsoft])
    }

    /// ⛔ THE WEB'S RULE: a missing row and an unknown status are both "Not connected".
    func testAMissingOrUnknownConnectionReadsAsNotConnected() throws {
        let body = #"""
        {"connections":[{"provider":"microsoft-calendar","status":"pending"}],
        "calendar":{"activeProvider":"microsoft","source":"preference"}}
        """#
        let response = try JSONDecoder().decode(ConnectionsResponse.self, from: Data(body.utf8))
        XCTAssertEqual(IntegrationsModel.rows(from: response), [
            IntegrationsCalendarRow(provider: .google, status: .absent, isActiveProvider: false),
            IntegrationsCalendarRow(provider: .microsoft, status: .absent, isActiveProvider: false),
        ])
        XCTAssertEqual(IntegrationsCalendarStatus(wire: "revoked"), .revoked)
        XCTAssertEqual(IntegrationsCalendarStatus(wire: nil), .absent)
    }

    func testEachStatusHasItsOwnWords() {
        let labels = [IntegrationsCalendarStatus.active, .error, .revoked, .absent].map(\.label)
        XCTAssertEqual(labels, ["Connected", "Reconnection needed", "Access revoked", "Not connected"])
    }

    func testAFailedReadIsShownAndOffersARetry() async {
        let model = model(SettingsTransport(responses: [(500, #"{"error":"boom"}"#)]))
        await model.load()

        guard case let .failed(failure) = model.state else {
            return XCTFail("expected a failure, got \(model.state)")
        }
        XCTAssertEqual(failure.action, .retry)
    }

    func testThePageIsTheWebsIntegrationsPageOnTheSameHost() throws {
        let staging = try XCTUnwrap(URL(string: "https://staging.example.test/api?x=1#y"))
        let url = try XCTUnwrap(IntegrationsView.destination(baseURL: staging))
        XCTAssertEqual(url.absoluteString, "https://staging.example.test/dashboard/district/studio/integrations")
        let plain = try XCTUnwrap(URL(string: "http://127.0.0.1:8080"))
        XCTAssertNil(IntegrationsView.destination(baseURL: plain), "SFSafariViewController traps on http")
    }
}
