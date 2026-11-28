@testable import DistrictAI
import SwiftUI
import XCTest

/// States no other file draws: the dialer's call-back list when nobody has called in and when
/// the calls could not be read, and the two-step scan card when the service's QR code is not a
/// picture and when the authenticator's code was refused.
final class DialerAndTwoStepStatesSnapshotTests: ScreenSnapshotTestCase {
    private static let workspace = "ws-contract-test"
    private static let calls = "/api/district/calls"

    // MARK: - The dialer's call-backs

    /// ⚠️ AN EMPTY LIST IS AN EXPLAINED ABSENCE: no inbound call to return, said in words.
    func testDialerNoCallbacks() async throws {
        try await assertScreen([Self.calls: .json("[]")], devices: [.iPhone]) { container in
            DialerView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    /// ⛔ A FAILED READ IS A FAILURE, NEVER AN EMPTY LIST: the keypad stands and the call-backs
    /// say they could not be read.
    func testDialerCallbacksUnreadable() async throws {
        try await assertScreen(
            [Self.calls: .json(#"{"error":"Something went wrong."}"#, status: 500)],
            devices: [.iPhone]
        ) { container in
            DialerView(container: container, workspaceId: Self.workspace, role: .client)
        }
    }

    // MARK: - The two-step scan card

    /// The service's QR code did not decode as a picture: the card says so and keeps the key
    /// to type in by hand.
    func testTwoStepScanCardWithAnUnreadableQRCode() async throws {
        let model = await TwoStepFixtures.scanning(then: [])
        let shown = try XCTUnwrap(model.enrollment)
        let enrollment = TwoStepModel.Enrollment(secret: shown.secret, otpauthURI: shown.otpauthURI, qrPNG: nil)
        try await assertScreen(devices: [.iPhone]) { _ in
            ScrollView { TwoStepScanCard(model: model, enrollment: enrollment).padding() }
        }
    }

    /// The service refused the authenticator's code: still on the scan step, the field cleared
    /// and the refusal under it.
    ///
    /// ⚠️ ENGLISH ONLY: the model stores the refusal's sentence when the code is refused, before
    /// the harness sets a language, so a French drawing would carry the English sentence.
    func testTwoStepScanCardCodeRefused() async throws {
        let model = await TwoStepFixtures.scanning(then: [
            (400, #"{"error":"That code did not match. Try the current one.","code":"mfa_code_invalid"}"#),
        ])
        model.totp = "000000"
        await model.confirm()
        XCTAssertEqual(model.step, .scan)
        XCTAssertEqual(model.totp, "")
        XCTAssertNotNil(model.failure)
        let enrollment = try XCTUnwrap(model.enrollment)
        try await assertScreen(devices: [.iPhone], locales: [.en]) { _ in
            ScrollView { TwoStepScanCard(model: model, enrollment: enrollment).padding() }
        }
    }
}
