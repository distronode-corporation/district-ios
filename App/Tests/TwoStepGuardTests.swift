@testable import DistrictAI
import DistrictData
import DistrictL10n
import DistrictModel
import DistrictNetwork
import Foundation
import UIKit
import XCTest

/// The two-step sheet's guards: every refusal's sentence and next step, French, single flight,
/// and that no secret outlives the sheet or reaches a print.
@MainActor
final class TwoStepGuardTests: XCTestCase {
    private struct Row {
        let error: ApiError
        let change: TwoStepModel.Change
        let message: String
        let next: TwoStepModel.Next

        init(_ error: ApiError, _ change: TwoStepModel.Change, _ message: String, _ next: TwoStepModel.Next) {
            self.error = error
            self.change = change
            self.message = message
            self.next = next
        }
    }

    // MARK: - Refusals

    /// Every refusal the three changes can answer, and where it leaves the sheet.
    func testEveryRefusalHasASentenceAndANextStep() {
        let rows: [Row] = [
            Row(.transport("offline"), .enroll, TwoStepCopy.errorOfflineNothingChanged, .stay),
            Row(.transport("offline"), .confirm, TwoStepCopy.errorOutcomeUnknownOn, .reread),
            Row(.transport("offline"), .disable, TwoStepCopy.errorOutcomeUnknownOff, .reread),
            Row(.decoding("x"), .enroll, TwoStepCopy.errorTryAgain, .stay),
            Row(.decoding("x"), .disable, TwoStepCopy.errorOutcomeUnknownOff, .reread),
            Row(
                .http(status: 403, message: "x", code: "reauth_required"),
                .enroll,
                TwoStepCopy.errorProofExpired,
                .reauth(.turnOn)
            ),
            Row(
                .http(status: 403, message: "x", code: "reauth_required"),
                .disable,
                TwoStepCopy.errorProofExpired,
                .reauth(.turnOff)
            ),
            Row(
                .http(status: 403, message: "x", code: "browser_session_required"), .disable,
                ApiErrorText.sentence(for: "browser_session_required") ?? "", .stay
            ),
            Row(
                .http(status: 429, message: "x", code: "rate_limited"),
                .confirm,
                ApiErrorText.sentence(for: "rate_limited") ?? "",
                .stay
            ),
            Row(
                .http(status: 500, message: "Internal server error", code: "server_error"),
                .enroll,
                TwoStepCopy.errorTryAgain,
                .stay
            ),
            Row(
                .http(status: 401, message: "Unauthorized", code: nil),
                .disable,
                SessionCopy.sessionHasEndedPlease,
                .stay
            ),
            Row(
                .http(status: 418, message: "A sentence from the service.", code: "brand_new_code"),
                .enroll,
                "A sentence from the service.",
                .stay
            ),
            Row(.http(status: 418, message: nil, code: nil), .enroll, TwoStepCopy.errorTryAgain, .stay),
        ]
        for row in rows {
            let outcome = TwoStepModel.refusal(row.error, during: row.change)
            XCTAssertEqual(outcome.message, row.message, "\(row.error) during \(row.change)")
            XCTAssertEqual(outcome.next, row.next, "\(row.error) during \(row.change)")
            XCTAssertFalse(outcome.message.isEmpty, "\(row.error) during \(row.change)")
        }
    }

    /// ⛔ NO ENGLISH ON A FRENCH SCREEN: the core's French, not the service's English.
    func testAFrenchRefusalIsInFrench() {
        let saved = L10nRuntime.locale
        L10nRuntime.locale = .frCA
        defer { L10nRuntime.locale = saved }
        let already = TwoStepModel.refusal(
            .http(status: 409, message: "Two-factor authentication is already enabled", code: "MFA_ALREADY_ENABLED"),
            during: .enroll
        )
        XCTAssertEqual(already.message, "La vérification en deux étapes est déjà active sur ce compte.")
        let unknown = TwoStepModel.refusal(
            .http(status: 418, message: "English only", code: "brand_new_code"),
            during: .enroll
        )
        XCTAssertEqual(unknown.message, TwoStepCopy.errorTryAgain)
        XCTAssertTrue(unknown.message.hasPrefix("Un problème"), unknown.message)
    }

    // MARK: - Single flight

    /// ⛔ TWO TAPS BEFORE A RE-RENDER SEND ONE CONFIRM.
    func testTwoConcurrentConfirmsSendOne() async {
        let transport = SettingsTransport([
            TwoStepFixtures.statusOff,
            TwoStepFixtures.proof,
            TwoStepFixtures.enrolled,
            TwoStepFixtures.confirmed,
            TwoStepFixtures.confirmed,
        ])
        let model = TwoStepHarness(transport).model
        await TwoStepFixtures.drive(model, toScanWith: "pw")
        model.totp = "123456"
        let before = transport.requests.count

        async let first: Void = model.confirm()
        async let second: Void = model.confirm()
        _ = await (first, second)

        XCTAssertEqual(transport.requests.count, before + 1)
    }

    func testTwoConcurrentPasswordTriesSendOne() async {
        let transport = SettingsTransport([
            TwoStepFixtures.statusOff,
            TwoStepFixtures.proof,
            TwoStepFixtures.enrolled,
            TwoStepFixtures.proof,
        ])
        let model = TwoStepHarness(transport).model
        await model.load()
        model.begin(.turnOn)
        model.usePassword()
        model.password = "pw"

        async let first: Void = model.submitPassword()
        async let second: Void = model.submitPassword()
        _ = await (first, second)

        XCTAssertEqual(transport.paths.filter { $0 == "/api/auth/native/reauth/password" }.count, 1)
    }

    func testTwoConcurrentSignInsOpenOneSheet() async {
        let transport = SettingsTransport([
            TwoStepFixtures.statusOff,
            TwoStepFixtures.enrolled,
            TwoStepFixtures.enrolled,
        ])
        let harness = TwoStepHarness(transport, sso: .proved(expiresInSeconds: 300))
        await harness.model.load()
        harness.model.begin(.turnOn)

        async let first: Void = harness.model.reauthenticate(with: .google)
        async let second: Void = harness.model.reauthenticate(with: .google)
        _ = await (first, second)

        XCTAssertEqual(harness.providers.count, 1)
        XCTAssertEqual(transport.paths.filter { $0 == "/api/auth/mfa/enroll" }.count, 1)
    }

    /// ⚠️ THE STATUS DECIDES WHICH CHANGE IS OFFERED: a stale button never starts the other.
    func testNothingStartsThatTheStatusDoesNotOffer() async {
        let transport = SettingsTransport([TwoStepFixtures.statusOn])
        let model = TwoStepHarness(transport).model
        model.begin(.turnOff)
        XCTAssertEqual(model.step, .loading, "nothing before the status")
        await model.load()
        model.begin(.turnOn)
        XCTAssertEqual(model.step, .overview, "already on")
        await model.confirm()
        await model.submitPassword()
        XCTAssertEqual(transport.requests.count, 1, "no confirm and no password outside their steps")
    }

    // MARK: - Leaving, and redaction

    func testLeavingDropsEverySecret() async {
        let model = await TwoStepFixtures.scanning(then: [])
        model.totp = "123"
        model.leave()
        XCTAssertNil(model.enrollment)
        XCTAssertEqual(model.totp, "")

        let codes = TwoStepHarness(SettingsTransport([
            TwoStepFixtures.statusOff,
            TwoStepFixtures.proof,
            TwoStepFixtures.enrolled,
            TwoStepFixtures.confirmed,
        ])).model
        await TwoStepFixtures.drive(codes, toScanWith: "pw")
        codes.totp = "123456"
        await codes.confirm()
        XCTAssertFalse(codes.recoveryCodes.isEmpty)
        codes.password = "typed"
        codes.leave()
        XCTAssertEqual(codes.recoveryCodes, [])
        XCTAssertEqual(codes.password, "")
    }

    /// ⛔ NOTHING PRINTS A SECRET: not the model, not its enrolment, not the core's DTOs.
    func testNoPrintOrDumpShowsTheSecretOrTheCodes() async {
        let model = await TwoStepFixtures.scanning(then: [])
        let enrollment = try? XCTUnwrap(model.enrollment)
        let response = try? JSONDecoder().decode(MfaEnrollResponse.self, from: Data(TwoStepFixtures.enrolled.utf8))
        let confirmed = try? JSONDecoder().decode(MfaConfirmResponse.self, from: Data(TwoStepFixtures.confirmed.utf8))
        var dumps = ""
        dump(model, to: &dumps)
        dump(enrollment, to: &dumps)
        dump(response, to: &dumps)
        dump(confirmed, to: &dumps)
        let printed = [
            String(describing: enrollment), String(reflecting: enrollment),
            String(describing: response), String(reflecting: response),
            String(describing: confirmed), String(reflecting: confirmed),
            String(describing: model), dumps,
        ]
        for text in printed {
            for secret in ["JBSWY3DP", "otpauth://", "iVBORw0K", "aaaa-bbbb", "cccc-dddd"] {
                XCTAssertFalse(text.contains(secret), "\(secret) in \(text)")
            }
        }
        XCTAssertTrue(String(describing: enrollment).contains("<redacted>"))
    }

    func testTheQRCodeIsReadOnlyFromAPNGDataURL() {
        XCTAssertNotNil(TwoStepModel.png(fromDataURL: "data:image/png;base64,\(TwoStepFixtures.pixel)")
            .flatMap(UIImage.init(data:)))
        XCTAssertNil(TwoStepModel.png(fromDataURL: "data:image/svg+xml;base64,\(TwoStepFixtures.pixel)"))
        XCTAssertNil(TwoStepModel.png(fromDataURL: "https://example.test/qr.png"))
    }

    func testTheKeyIsGroupedForReadingOnly() {
        XCTAssertEqual(TwoStepSecret.grouped("JBSWY3DPEHPK3PXP"), "JBSW Y3DP EHPK 3PXP")
        XCTAssertEqual(TwoStepSecret.grouped("ABCDEF"), "ABCD EF")
        XCTAssertEqual(TwoStepSecret.grouped(""), "")
    }
}
