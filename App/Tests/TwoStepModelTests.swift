@testable import DistrictAI
import DistrictData
import DistrictL10n
import DistrictModel
import DistrictNetwork
import Foundation
import UIKit
import XCTest

/// Two-step verification in the app: the status, turning it on (re-authentication, the new
/// secret, the confirming code, the recovery codes once) and off, and every refusal on the way.
///
/// ⛔ THE REAL REPOSITORIES OVER A CANNED TRANSPORT, so each refusal arrives exactly as the
/// service sends it (status, `error` and `code`) and the request bodies are the bytes sent.
@MainActor
final class TwoStepModelTests: XCTestCase {
    // MARK: - Reading

    func testTheStatusIsReadOnOpen() async {
        let transport = SettingsTransport([TwoStepFixtures.statusOn])
        let model = TwoStepHarness(transport).model
        XCTAssertEqual(model.step, .loading)

        await model.load()

        XCTAssertEqual(model.step, .overview)
        XCTAssertEqual(model.status?.enrolled, true)
        XCTAssertEqual(model.status?.backupCodesRemaining, 7)
        XCTAssertEqual(transport.paths, ["/api/auth/mfa"])
        XCTAssertEqual(transport.requests.first?.method, .get)
    }

    func testAFirstReadThatFailsOffersRetry() async {
        let offline = TwoStepHarness(OfflineTransport()).model
        await offline.load()
        XCTAssertEqual(offline.step, .loadFailed)
        XCTAssertEqual(offline.failure, TwoStepCopy.errorOfflineLoad)

        let transport = SettingsTransport(responses: [
            (500, #"{"error":"Internal","code":"server_error"}"#),
            (200, TwoStepFixtures.statusOff),
        ])
        let model = TwoStepHarness(transport).model
        await model.load()
        XCTAssertEqual(model.failure, TwoStepCopy.errorLoad)
        await model.load()
        XCTAssertEqual(model.step, .overview)
        XCTAssertNil(model.failure)
    }

    /// ⛔ A 200 WHOSE `enrolled` DISAGREES WITH `enrolledAt` is the core's decoding failure.
    func testAnInconsistentStatusIsNotShownAsOn() async {
        let model = TwoStepHarness(SettingsTransport([
            #"{"enrolled":true,"enrolledAt":null,"backupCodesRemaining":0,"canDisable":true}"#,
        ])).model
        await model.load()
        XCTAssertEqual(model.step, .loadFailed)
        XCTAssertNil(model.status)
    }

    // MARK: - Turning on

    func testTurningOnWithThePasswordShowsTheSecretThenTheCodesOnce() async {
        let transport = SettingsTransport(responses: [
            (200, TwoStepFixtures.statusOff), (200, TwoStepFixtures.proof), (200, TwoStepFixtures.enrolled), (
                200,
                TwoStepFixtures.confirmed
            ), (200, TwoStepFixtures.statusOn),
        ])
        let model = TwoStepHarness(transport).model
        await model.load()

        model.begin(.turnOn)
        XCTAssertEqual(model.step, .reauth(.turnOn))
        model.usePassword()
        model.password = "correct horse"
        await model.submitPassword()

        XCTAssertEqual(model.step, .scan)
        XCTAssertEqual(model.password, "", "the password is not kept after the attempt")
        XCTAssertEqual(model.enrollment?.secret, "JBSWY3DPEHPK3PXP")
        let png = try? XCTUnwrap(model.enrollment?.qrPNG)
        XCTAssertNotNil(png.flatMap(UIImage.init(data:)), "the QR code decodes to an image")
        XCTAssertFalse(model.canConfirm, "no confirm without a code")

        model.totp = " 123456 "
        await model.confirm()
        XCTAssertEqual(model.step, .recoveryCodes)
        XCTAssertEqual(model.recoveryCodes, ["aaaa-bbbb", "cccc-dddd"])
        XCTAssertNil(model.enrollment, "the secret is dropped once confirmed")
        XCTAssertEqual(model.status?.enrolled, true, "on, even before the next read")

        await model.finishRecoveryCodes()
        XCTAssertEqual(model.step, .overview)
        XCTAssertEqual(model.recoveryCodes, [], "the codes are shown once")
        XCTAssertEqual(model.notice, TwoStepCopy.turnedOn)

        XCTAssertEqual(transport.paths, [
            "/api/auth/mfa", "/api/auth/native/reauth/password", "/api/auth/mfa/enroll",
            "/api/auth/mfa/confirm", "/api/auth/mfa",
        ])
        XCTAssertEqual(transport.bodies, [
            #"{"action":"2fa-change","password":"correct horse"}"#,
            #"{"totp":"123456"}"#,
        ])
    }

    func testAFreshSignInAtTheProviderAlsoEnrols() async {
        let transport = SettingsTransport([TwoStepFixtures.statusOff, TwoStepFixtures.enrolled])
        let harness = TwoStepHarness(transport, sso: .proved(expiresInSeconds: 300))
        await harness.model.load()
        harness.model.begin(.turnOn)
        await harness.model.reauthenticate(with: .microsoft)

        XCTAssertEqual(harness.providers, [.microsoft])
        XCTAssertEqual(harness.model.step, .scan)
        XCTAssertEqual(transport.paths.last, "/api/auth/mfa/enroll")
    }

    func testACancelledOrUnverifiedSignInChangesNothing() async {
        for (outcome, message) in [
            (SSOReauthOutcome.cancelled, nil),
            (.stateMismatch, DeleteAccountCopy.errorSignInNotVerified),
            (.couldNotOpen, DeleteAccountCopy.errorSheetDidNotOpen),
        ] {
            let transport = SettingsTransport([TwoStepFixtures.statusOff])
            let harness = TwoStepHarness(transport, sso: outcome)
            await harness.model.load()
            harness.model.begin(.turnOn)
            await harness.model.reauthenticate(with: .google)
            XCTAssertEqual(harness.model.step, .reauth(.turnOn), "\(outcome)")
            XCTAssertEqual(harness.model.failure, message, "\(outcome)")
            XCTAssertEqual(transport.requests.count, 1, "only the status read")
        }
    }

    func testAWrongCodeKeepsTheSecretAndClearsTheCode() async {
        let model = await TwoStepFixtures.scanning(then: [
            (400, #"{"error":"Invalid code","code":"mfa_code_invalid"}"#),
        ])
        model.totp = "000000"
        await model.confirm()

        XCTAssertEqual(model.step, .scan)
        XCTAssertNotNil(model.enrollment)
        XCTAssertEqual(model.totp, "")
        XCTAssertEqual(model.failure, ApiErrorText.sentence(for: "mfa_code_invalid"))
    }

    /// ⚠️ A PROOF THAT RAN OUT MEANS A NEW SECRET: the old one is dropped with it.
    func testAnExpiredProofGoesBackToConfirmItIsYou() async {
        let model = await TwoStepFixtures.scanning(then: [
            (403, #"{"error":"Confirm it is you again.","code":"reauth_required"}"#),
        ])
        model.totp = "123456"
        await model.confirm()

        XCTAssertEqual(model.step, .reauth(.turnOn))
        XCTAssertNil(model.enrollment)
        XCTAssertEqual(model.failure, TwoStepCopy.errorProofExpired)
    }

    /// ⛔ A CONFIRM WHOSE ANSWER CANNOT BE READ MAY HAVE TURNED IT ON: never claim either way,
    /// and read again (a lost connection is the same row in the refusal table below).
    func testAnUnreadableConfirmSaysItCannotTellAndReadsAgain() async {
        let model = await TwoStepFixtures.scanning(then: [
            (200, #"{"enrolled":false,"backupCodes":[]}"#),
            (200, TwoStepFixtures.statusOn),
        ])
        model.totp = "123456"
        await model.confirm()

        XCTAssertEqual(model.step, .overview)
        XCTAssertEqual(model.failure, TwoStepCopy.errorOutcomeUnknownOn)
        XCTAssertEqual(model.status?.enrolled, true)
        XCTAssertNil(model.enrollment)
        XCTAssertEqual(model.recoveryCodes, [])
    }

    func testAlreadyOnOrNotStartedReadsTheStatusAgain() async {
        for code in ["MFA_ALREADY_ENABLED", "MFA_NOT_STARTED", "MFA_NOT_PENDING"] {
            let transport = SettingsTransport(responses: [
                (200, TwoStepFixtures.statusOff), (200, TwoStepFixtures.proof), (
                    400,
                    #"{"error":"x","code":"\#(code)"}"#
                ), (
                    200,
                    TwoStepFixtures.statusOn
                ),
            ])
            let model = TwoStepHarness(transport).model
            await model.load()
            model.begin(.turnOn)
            model.usePassword()
            model.password = "pw"
            await model.submitPassword()

            XCTAssertEqual(model.step, .overview, code)
            XCTAssertEqual(model.status?.enrolled, true, code)
            XCTAssertEqual(model.failure, ApiErrorText.sentence(for: code), code)
        }
    }

    // MARK: - Turning off

    /// ⛔ TWO-STEP ACCOUNTS RE-AUTHENTICATE WITH THEIR CODE (Sean, 2026-11-07).
    func testTurningOffAsksForTheCodeThenDisables() async {
        let transport = SettingsTransport(responses: [
            (200, TwoStepFixtures.statusOn),
            (401, #"{"error":"Enter the code.","code":"MFA_REQUIRED"}"#),
            (200, TwoStepFixtures.proof),
            (200, #"{"enrolled":false}"#),
            (200, TwoStepFixtures.statusOff),
        ])
        let model = TwoStepHarness(transport).model
        await model.load()
        model.begin(.turnOff)
        model.usePassword()
        model.password = "pw"
        await model.submitPassword()
        XCTAssertEqual(model.step, .password(.turnOff, needsCode: true))
        XCTAssertNil(model.failure, "asking for the code is not a failure")

        model.password = "pw"
        model.code = " 123456 "
        await model.submitPassword()

        XCTAssertEqual(model.step, .overview)
        XCTAssertEqual(model.status?.enrolled, false)
        XCTAssertEqual(model.notice, TwoStepCopy.turnedOff)
        XCTAssertEqual(transport.bodies, [
            #"{"action":"2fa-change","password":"pw"}"#,
            #"{"action":"2fa-change","code":"123456","password":"pw"}"#,
        ])
        XCTAssertEqual(Array(transport.paths.suffix(2)), ["/api/auth/mfa/disable", "/api/auth/mfa"])
    }

    /// ⚠️ `canDisable` IS THE WEBSITE'S RULE: an account with no password turns it off here after
    /// a fresh provider sign-in, and the sheet says so.
    func testAnAccountWithNoPasswordTurnsItOffWithItsProvider() async {
        let transport = SettingsTransport([
            #"{"enrolled":true,"enrolledAt":"2026-10-01T12:00:00.000Z","backupCodesRemaining":3,"canDisable":false}"#,
            #"{"enrolled":false}"#,
            TwoStepFixtures.statusOff,
        ])
        let harness = TwoStepHarness(transport, sso: .proved(expiresInSeconds: 300))
        await harness.model.load()
        XCTAssertTrue(harness.model.signsInWithoutPassword)

        harness.model.begin(.turnOff)
        await harness.model.reauthenticate(with: .apple)
        XCTAssertEqual(harness.model.status?.enrolled, false)
        XCTAssertEqual(transport.paths[1], "/api/auth/mfa/disable")
    }

    func testADisableWithNoAnswerSaysItCannotTell() async {
        let transport = SettingsTransport(responses: [
            (200, TwoStepFixtures.statusOn),
            (200, #"{"enrolled":true}"#),
            (200, TwoStepFixtures.statusOn),
        ])
        let harness = TwoStepHarness(transport, sso: .proved(expiresInSeconds: 300))
        await harness.model.load()
        harness.model.begin(.turnOff)
        await harness.model.reauthenticate(with: .google)

        XCTAssertEqual(harness.model.failure, TwoStepCopy.errorOutcomeUnknownOff)
        XCTAssertEqual(harness.model.status?.enrolled, true, "read again, and still on")
        XCTAssertNil(harness.model.notice, "never claims it is off")
    }

    func testADisableWithAnExpiredProofAsksAgainForTheSameChange() async {
        let transport = SettingsTransport(responses: [
            (200, TwoStepFixtures.statusOn), (403, #"{"error":"x","code":"reauth_required"}"#),
        ])
        let harness = TwoStepHarness(transport, sso: .proved(expiresInSeconds: 300))
        await harness.model.load()
        harness.model.begin(.turnOff)
        await harness.model.reauthenticate(with: .google)
        XCTAssertEqual(harness.model.step, .reauth(.turnOff))
        XCTAssertEqual(harness.model.failure, TwoStepCopy.errorProofExpired)
    }
}
