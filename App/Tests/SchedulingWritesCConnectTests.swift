@testable import DistrictAI
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// A transport that answers one canned HTTP response, redirects included.
///
/// ⛔ SEPARATE FROM `SchedulingWritesCTransport` BECAUSE THIS LEG IS NOT JSON. The
/// SSO route answers a **302** whose `Location` is read and never followed: the
/// URL carries a 60-second single-use token, so following it would spend the
/// credential on a transport the user never sees.
private final class SchedulingWritesCRedirectTransport: HTTPTransport, @unchecked Sendable {
    private let response: HTTPResponse
    private let lock = NSLock()
    private(set) var requests: [HTTPRequest] = []
    private(set) var followedRedirects: [Bool] = []

    init(status: Int, location: String?) {
        var headers: [String: String] = [:]
        if let location {
            headers["Location"] = location
        }
        response = HTTPResponse(statusCode: status, headers: headers, body: nil)
    }

    func send(_ request: HTTPRequest, followRedirects: Bool) async throws -> HTTPResponse {
        lock.withLock {
            requests.append(request)
            followedRedirects.append(followRedirects)
        }
        return response
    }
}

/// The calendar OAuth hand-off: the one write on this surface that leaves the app.
@MainActor
final class SchedulingWritesCConnectTests: XCTestCase {
    /// ⚠️ FORCE-UNWRAPPED, WHICH THIS REPO'S SwiftLint ALLOWS (`force_unwrapping` is
    /// an opt-in rule and no opt-in rules are enabled): the literal is a constant in
    /// this file, so the failure it could produce is a compile-time typo rather than
    /// anything a run can encounter. `ApiClient.productionBaseURL` does the same.
    private static let base = URL(string: "https://www.distronode.com")!

    private static let status = #"""
    {"connected":false,"configured":true,"providers":["google","microsoft","caldav"],
     "connections":[],"unconfigured_providers":["microsoft"],"provider":null}
    """#

    // MARK: - The `next` path

    /// ⛔ DOUBLE-ENCODED, AND THE INNER ENCODE IS THE LOAD-BEARING ONE. `safeNextPath`
    /// refuses any `next` containing a literal `://` — the check that stops an open
    /// redirect — and `return_to` is an ABSOLUTE URL, so encoding the return URL
    /// before it is placed in `next` is what lets an absolute URL travel inside a
    /// value that may not contain one. A single encode reads correctly and has its
    /// `next` dropped on the floor at the far end.
    func test_IOS_SCHW_C70_theNextPathHidesTheAbsoluteReturnUrlFromTheOpenRedirectGuard() {
        let next = SchedulingCalendarConnectModel.nextPath(
            provider: "google",
            returnTo: "https://www.distronode.com/dashboard/district/scheduling/calendar"
        )
        XCTAssertTrue(next.hasPrefix("/v1/calendar/connect?provider=google&return_to="))
        XCTAssertFalse(next.contains("://"), "safeNextPath drops any next containing a scheme")
        XCTAssertTrue(next.contains("https%3A%2F%2Fwww.distronode.com"))
    }

    /// ⛔ AND THE OUTER ENCODE IS THE ONE `URLComponents` WOULD HAVE GOT WRONG.
    /// `CharacterSet.urlQueryAllowed` CONTAINS `?`, `&` and `=`, so a `queryItems`
    /// assignment would have sent `return_to` as a sibling parameter of `next`
    /// rather than as part of it — and every step after that is silent.
    func test_IOS_SCHW_C71_theRequestCarriesOneNextParameterWithItsQueryIntact() async throws {
        let transport = SchedulingWritesCRedirectTransport(
            status: 302,
            location: "https://scheduling-us.distronode.com/v1/auth/sso?token=abc"
        )
        let model = Self.model(transport)
        _ = await model.connect(provider: "google")

        let sent = try XCTUnwrap(transport.requests.first?.url)
        let components = try XCTUnwrap(URLComponents(url: sent, resolvingAgainstBaseURL: false))
        XCTAssertEqual(sent.path, "/api/district/scheduling/sso")
        XCTAssertNil(components.queryItems?.first { $0.name == "return_to" }, "return_to must live INSIDE next")
        let next = try XCTUnwrap(components.queryItems?.first { $0.name == "next" }?.value)
        XCTAssertTrue(next.hasPrefix("/v1/calendar/connect?provider=google&return_to="))
        XCTAssertEqual(components.queryItems?.first { $0.name == "workspaceId" }?.value, "ws_1")
    }

    /// ⛔ THE 302 IS READ, NOT FOLLOWED. Following it spends a single-use credential
    /// on a transport the operator never sees.
    func test_IOS_SCHW_C72_theRedirectIsReadRatherThanFollowed() async {
        let target = "https://scheduling-us.distronode.com/v1/auth/sso?token=abc"
        let transport = SchedulingWritesCRedirectTransport(status: 302, location: target)
        let model = Self.model(transport)

        let url = await model.connect(provider: "google")
        XCTAssertEqual(url?.absoluteString, target)
        XCTAssertEqual(transport.followedRedirects, [false])
        XCTAssertNil(model.failure)
    }

    /// ⛔ HTTPS ONLY, CHECKED RATHER THAN TRUSTED. `SFSafariViewController` traps on
    /// anything that is not http or https, so an unexpected scheme would be a crash
    /// rather than a refusal — and a hand-off that is not TLS would put the token on
    /// the wire in clear.
    func test_IOS_SCHW_C73_aNonHttpsLocationIsRefusedRatherThanOpened() async {
        let transport = SchedulingWritesCRedirectTransport(status: 302, location: "districtai://calendar")
        let model = Self.model(transport)

        let url = await model.connect(provider: "google")
        XCTAssertNil(url)
        XCTAssertNotNil(model.failure)
    }

    /// ⚠️ 409 IS NOT A FAULT: the route answers it when the tenancy is not `ready`,
    /// which is the honest state of a workspace mid-provision.
    func test_IOS_SCHW_C74_aTenancyThatIsNotReadyYetSaysSoRatherThanFailing() async {
        let transport = SchedulingWritesCRedirectTransport(status: 409, location: nil)
        let model = Self.model(transport)

        _ = await model.connect(provider: "google")
        XCTAssertEqual(model.failure?.message, SchedulingWriteCopyC.connectNotReadyYet)
        XCTAssertEqual(model.failure?.action, FailureText.Action.none)
    }

    // MARK: - Which providers are offered

    /// ⛔ THE TWO NAMES ARE THE FORK'S AND `caldav` IS NOT ONE OF THEM. It is a third
    /// provider with no OAuth redirect, and `GET /v1/calendar/connect?provider=`
    /// 400s on anything outside `google` and `microsoft` — so listing what
    /// `providers` happens to carry would draw a button that cannot work.
    func test_IOS_SCHW_C75_onlyTheConfiguredOauthProvidersAreOffered() throws {
        let status: SchedulingCalendarStatus = try SchedulingWritesCRows.decode(Self.status)
        XCTAssertEqual(SchedulingCalendarConnectModel.offeredProviders(status), ["google"])
    }

    /// ⚠️ `unconfigured_providers` IS NULL, NOT `[]`, ON A FULLY CONFIGURED INSTANCE
    /// — the common case — so nil has to mean "none are missing" rather than
    /// "nothing is available".
    func test_IOS_SCHW_C76_aNullUnconfiguredListMeansBothProvidersAreOffered() throws {
        let json = #"""
        {"connected":true,"configured":true,"providers":null,"connections":[],
         "unconfigured_providers":null,"provider":"google"}
        """#
        let status: SchedulingCalendarStatus = try SchedulingWritesCRows.decode(json)
        XCTAssertEqual(SchedulingCalendarConnectModel.offeredProviders(status), ["google", "microsoft"])
    }

    /// ⛔ AN INSTANCE WITH NO CALENDAR CREDENTIALS GETS NO CONTROLS. `configured` is
    /// the INSTANCE's answer and `connected` is the caller's; a button that could
    /// only fail is worse than a sentence.
    func test_IOS_SCHW_C77_anUnconfiguredInstanceOffersNothing() throws {
        let json = #"""
        {"connected":false,"configured":false,"providers":null,"connections":[],
         "unconfigured_providers":null,"provider":null}
        """#
        let status: SchedulingCalendarStatus = try SchedulingWritesCRows.decode(json)
        XCTAssertTrue(SchedulingCalendarConnectModel.offeredProviders(status).isEmpty)
    }

    // MARK: - Coming back

    /// ⚠️ THE APP IS NOT TOLD WHAT HAPPENED IN THE BROWSER. The callback appends
    /// `calendar=connected` or `calendar=error` to a page this process never sees,
    /// so the sheet's dismissal re-reads the status and lets it say what is
    /// connected.
    func test_IOS_SCHW_C78_closingTheBrowserAsksForAReRead() {
        let transport = SchedulingWritesCRedirectTransport(status: 302, location: nil)
        var changed = 0
        let model = SchedulingCalendarConnectModel(
            sso: Self.sso(transport),
            baseURL: Self.base,
            workspaceId: "ws_1",
            onChanged: { changed += 1 }
        )
        model.handOffFinished()
        XCTAssertEqual(changed, 1)
    }

    func test_IOS_SCHW_C79_theReturnUrlIsTheDashboardCalendarPageOnThisBuildsHost() {
        let transport = SchedulingWritesCRedirectTransport(status: 302, location: nil)
        let model = Self.model(transport)
        XCTAssertEqual(
            model.returnTo,
            "https://www.distronode.com/dashboard/district/scheduling/calendar"
        )
    }

    // MARK: - Fixtures

    private static func sso(_ transport: any HTTPTransport) -> SchedulingSSOClient {
        SchedulingSSOClient(
            baseURL: base,
            transport: transport,
            accessToken: { "session-token" }
        )
    }

    private static func model(_ transport: any HTTPTransport) -> SchedulingCalendarConnectModel {
        SchedulingCalendarConnectModel(
            sso: sso(transport),
            baseURL: base,
            workspaceId: "ws_1",
            onChanged: {}
        )
    }
}
