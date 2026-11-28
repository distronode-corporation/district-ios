import AuthenticationServices
@testable import DistrictAI
import DistrictAuthCore
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The re-authentication sheet's remaining guards, with hostile callbacks: an empty code, a
/// callback with no query, a doubled `state`, an attempt abandoned by a second one, and the
/// sheet's address over a base with no trailing slash. ⚠️ The presenter is the only double,
/// as in `ReauthSheetControllerTests`; `ASWebAuthenticationSession` itself is not reached.
@MainActor
final class ReauthSheetMarginTests: XCTestCase {
    private static let proof = #"{"success":true,"action":"delete-account","expiresInSeconds":120}"#

    func testTheAddressOverABaseWithNoTrailingSlashHasOneSlash() throws {
        let challenge = PKCEChallenge(verifier: "v", challenge: "c", state: "s")
        let url = try XCTUnwrap(try ReauthSheetController.sheetURL(
            baseURL: XCTUnwrap(URL(string: "https://staging.example.test")),
            challenge: challenge,
            provider: .apple,
            deviceHash: "",
            action: .deleteAccount
        ))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.host, "staging.example.test")
        XCTAssertEqual(parts.path, "/auth/native/reauth")
        XCTAssertEqual(parts.queryItems?.first { $0.name == "provider" }?.value, "apple")
        XCTAssertEqual(parts.queryItems?.first { $0.name == "device" }?.value, "", "an empty hash is sent as given")
    }

    /// ⚠️ A base with a path keeps it: the page is under the base, not at the host's root.
    func testABaseWithAPathKeepsIt() throws {
        let challenge = PKCEChallenge(verifier: "v", challenge: "c", state: "s")
        let url = try XCTUnwrap(try ReauthSheetController.sheetURL(
            baseURL: XCTUnwrap(URL(string: "https://example.test/app/")),
            challenge: challenge,
            provider: .google,
            deviceHash: "h",
            action: .deleteAccount
        ))
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.path, "/app/auth/native/reauth")
    }

    /// Each attempt makes its own handshake: two sheets never share a state or a challenge.
    func testEveryAttemptHasAFreshHandshake() async {
        let sheets = ReauthSheets()
        let controller = Self.controller(SettingsTransport([])) { url in
            sheets.urls.append(url)
            return .failure(ASWebAuthenticationSessionError(.canceledLogin))
        }
        _ = await controller.reauthenticate(provider: .google, action: .deleteAccount)
        _ = await controller.reauthenticate(provider: .google, action: .deleteAccount)

        XCTAssertEqual(sheets.urls.count, 2)
        let states = sheets.urls.compactMap { Self.query($0, "state") }
        let challenges = sheets.urls.compactMap { Self.query($0, "code_challenge") }
        XCTAssertEqual(Set(states).count, 2)
        XCTAssertEqual(Set(challenges).count, 2)
    }

    func testAnEmptyCodeIsNoCode() async {
        let transport = SettingsTransport([])
        let controller = Self.controller(transport) { url in
            .success(URL(string: "districtai://auth?code=&state=\(Self.query(url, "state") ?? "")")!)
        }
        let outcome = await controller.reauthenticate(provider: .google, action: .deleteAccount)
        XCTAssertEqual(outcome, .noCode)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testACallbackWithNoQueryIsAStateMismatch() async {
        let transport = SettingsTransport([])
        let controller = Self.controller(transport) { _ in .success(URL(string: "districtai://auth")!) }
        let outcome = await controller.reauthenticate(provider: .microsoft, action: .deleteAccount)
        XCTAssertEqual(outcome, .stateMismatch)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    /// ⛔ The FIRST `state` is the one checked: a foreign one ahead of ours is refused.
    func testADoubledStateIsJudgedByItsFirstValue() async {
        let transport = SettingsTransport([])
        let controller = Self.controller(transport) { url in
            let ours = Self.query(url, "state") ?? ""
            return .success(URL(string: "districtai://auth?state=foreign&state=\(ours)&code=x")!)
        }
        let outcome = await controller.reauthenticate(provider: .google, action: .deleteAccount)
        XCTAssertEqual(outcome, .stateMismatch)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    /// ⛔ Single-slot: a second attempt abandons the first, so the first one's callback,
    /// arriving late with its own correct state, is never exchanged.
    func testASecondAttemptAbandonsTheFirst() async throws {
        let transport = SettingsTransport([Self.proof])
        let sheets = ReauthSheets()
        let controller = Self.controller(transport) { url in
            sheets.urls.append(url)
            if sheets.urls.count == 1 {
                try? await Task.sleep(for: .milliseconds(300))
            }
            return .success(Self.callback(echoing: url, code: "code-\(sheets.urls.count)"))
        }

        let first = Task { await controller.reauthenticate(provider: .google, action: .deleteAccount) }
        try await Task.sleep(for: .milliseconds(50))
        let second = await controller.reauthenticate(provider: .google, action: .deleteAccount)
        let firstOutcome = await first.value

        XCTAssertEqual(second, .proved(expiresInSeconds: 120))
        XCTAssertEqual(firstOutcome, .stateMismatch, "the abandoned attempt's verifier is gone")
        XCTAssertEqual(transport.requests.count, 1, "one code spent, the second attempt's")
    }

    func testOnlyClosingTheSheetCountsAsACancellation() {
        XCTAssertTrue(WebAuthSheet.isUserCancellation(ASWebAuthenticationSessionError(.canceledLogin)))
        XCTAssertFalse(WebAuthSheet.isUserCancellation(
            ASWebAuthenticationSessionError(.presentationContextNotProvided)
        ))
        XCTAssertFalse(WebAuthSheet.isUserCancellation(WebAuthLoginError.noCallback))
        XCTAssertFalse(WebAuthSheet.isUserCancellation(NSError(domain: "x", code: 1)))
    }

    // MARK: - Helpers

    private static func controller(
        _ transport: SettingsTransport,
        presenter: @escaping ReauthSheetController.Presenter
    ) -> ReauthSheetController {
        ReauthSheetController(
            baseURL: ApiClient.productionBaseURL,
            repository: NativeReauthRepository(client: ApiClient(
                baseURL: ApiClient.productionBaseURL,
                transport: transport,
                accessToken: { "session-token" }
            )),
            deviceId: "11111111-2222-3333-4444-555555555555",
            presenter: presenter
        )
    }

    private static func callback(echoing sheet: URL, code: String) -> URL {
        var parts = URLComponents(string: "districtai://auth")!
        parts.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "state", value: query(sheet, "state")),
        ]
        return parts.url!
    }

    private static func query(_ url: URL?, _ name: String) -> String? {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == name }?.value
    }
}

/// The sheet addresses a presenter was handed.
@MainActor
final class ReauthSheets {
    var urls: [URL] = []
}
