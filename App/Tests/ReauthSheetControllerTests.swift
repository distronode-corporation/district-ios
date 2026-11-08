import AuthenticationServices
@testable import DistrictAI
import DistrictAuthCore
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The SSO leg of the fresh re-authentication: the sheet's address, the callback's `state`,
/// and the code exchange.
///
/// ⛔ THE PRESENTER IS THE ONLY DOUBLE. It stands in for `ASWebAuthenticationSession` and
/// answers with a callback built from the address it was handed, as the service's sheet does;
/// the exchange runs through the real repository over a canned transport.
@MainActor
final class ReauthSheetControllerTests: XCTestCase {
    private static let deviceId = "11111111-2222-3333-4444-555555555555"

    func testTheSheetAddressCarriesTheHandshakeTheProviderTheHashedDeviceAndTheAction() throws {
        let challenge = PKCEChallenge(verifier: "v", challenge: "c-hall", state: "st")
        let url = try XCTUnwrap(try ReauthSheetController.sheetURL(
            baseURL: XCTUnwrap(URL(string: "https://www.distronode.com/")),
            challenge: challenge,
            provider: .microsoft,
            deviceHash: AppleNonce.sha256Hex(Self.deviceId),
            action: .deleteAccount
        ))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.host, "www.distronode.com")
        XCTAssertEqual(parts.path, "/auth/native/reauth", "one slash, the page and not an API route")
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query, [
            "code_challenge": "c-hall",
            "state": "st",
            "redirect_uri": "districtai://auth",
            "provider": "azure-ad",
            "device": AppleNonce.sha256Hex(Self.deviceId),
            "action": "delete-account",
        ])
        XCTAssertEqual(query["device"]?.count, 64, "SHA-256 in hex, never the installation id itself")
        XCTAssertFalse(url.absoluteString.contains(Self.deviceId))
    }

    func testTheProvidersAreTheServiceWireNames() {
        XCTAssertEqual(ReauthProvider.allCases.map(\.rawValue), ["google", "azure-ad", "apple"])
        XCTAssertEqual(ReauthProvider.allCases.map(\.displayName), ["Google", "Microsoft", "Apple"])
    }

    func testAMatchingCallbackSpendsTheCodeWithThisAttemptsVerifier() async throws {
        let transport = SettingsTransport([#"{"success":true,"action":"delete-account","expiresInSeconds":240}"#])
        var sheet: URL?
        let controller = Self.controller(transport) { url in
            sheet = url
            return .success(Self.callback(echoing: url, code: "one-time"))
        }

        let outcome = await controller.reauthenticate(provider: .google, action: .deleteAccount)

        XCTAssertEqual(outcome, .proved(expiresInSeconds: 240))
        XCTAssertEqual(transport.paths, ["/api/auth/native/reauth/sso"])
        let body = try XCTUnwrap(transport.bodies.first)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String])
        XCTAssertEqual(sent["action"], "delete-account")
        XCTAssertEqual(sent["code"], "one-time")
        XCTAssertEqual(sent["redirectUri"], "districtai://auth")
        let verifier = try XCTUnwrap(sent["codeVerifier"])
        let challenge = try XCTUnwrap(Self.query(sheet, "code_challenge"))
        XCTAssertEqual(PKCE.deriveChallenge(for: verifier), challenge, "the verifier behind the sheet's challenge")
    }

    /// ⛔ A CALLBACK THIS ATTEMPT DID NOT START IS NEVER EXCHANGED.
    func testAForeignStateIsRefusedWithoutSpendingTheCode() async {
        let transport = SettingsTransport([])
        let controller = Self.controller(transport) { _ in
            .success(URL(string: "districtai://auth?code=injected&state=someone-else")!)
        }
        let outcome = await controller.reauthenticate(provider: .google, action: .deleteAccount)
        XCTAssertEqual(outcome, .stateMismatch)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testACallbackWithoutACodeIsNotExchanged() async {
        let transport = SettingsTransport([])
        let controller = Self.controller(transport) { url in
            .success(URL(string: "districtai://auth?state=\(Self.query(url, "state") ?? "")")!)
        }
        let outcome = await controller.reauthenticate(provider: .apple, action: .deleteAccount)
        XCTAssertEqual(outcome, .noCode)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testClosingTheSheetIsACancellationAndAnyOtherFailureIsNotOpening() async {
        let cancelled = Self.controller(SettingsTransport([])) { _ in
            .failure(ASWebAuthenticationSessionError(.canceledLogin))
        }
        let broken = Self.controller(SettingsTransport([])) { _ in .failure(WebAuthLoginError.couldNotStart) }
        let first = await cancelled.reauthenticate(provider: .google, action: .deleteAccount)
        let second = await broken.reauthenticate(provider: .google, action: .deleteAccount)
        XCTAssertEqual(first, .cancelled)
        XCTAssertEqual(second, .couldNotOpen)
    }

    /// ⚠️ THE SERVICE'S REFUSAL KEEPS ITS CODE, for the model to word.
    func testARefusedExchangeKeepsTheServiceCode() async {
        let transport = SettingsTransport(
            [#"{"error":"We could not confirm it is you. Please try again.","code":"reauth_failed"}"#],
            status: 403
        )
        let controller = Self.controller(transport) { url in .success(Self.callback(echoing: url, code: "c")) }
        let outcome = await controller.reauthenticate(provider: .google, action: .deleteAccount)
        guard case let .refused(error) = outcome else {
            return XCTFail("expected a refusal, got \(outcome)")
        }
        XCTAssertEqual(error.code, "reauth_failed")
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
            deviceId: deviceId,
            presenter: presenter
        )
    }

    /// What the service's sheet hands back: the code, and the state it was given.
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
