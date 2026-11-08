@testable import DistrictAI
import DistrictData
import DistrictL10n
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// Deleting the account in the app: the fresh re-authentication, the typed email, and every
/// refusal the service can answer on the way.
///
/// ⛔ THE REAL REPOSITORY OVER A CANNED TRANSPORT, so each refusal arrives exactly as the
/// service sends it (status, `error` and `code`) and the request bodies are the bytes sent.
@MainActor
final class DeleteAccountModelTests: XCTestCase {
    // MARK: - The password path

    func testThePasswordEarnsAProofAndTheTypedEmailDeletes() async {
        let transport = SettingsTransport(responses: [(200, Self.proof), (200, Self.deletedBody)])
        let harness = Harness(transport)
        let model = harness.model

        model.usePassword()
        model.password = "correct horse"
        await model.submitPassword()
        XCTAssertEqual(model.step, .confirm)
        XCTAssertEqual(model.password, "", "the password is not kept after the attempt")

        model.confirmation = "  you@example.test "
        await model.delete()

        XCTAssertEqual(harness.deletions, [false], "deleted once, with no vendor erasure pending")
        XCTAssertEqual(transport.paths, ["/api/auth/native/reauth/password", "/api/auth/delete-account"])
        XCTAssertEqual(transport.bodies, [
            #"{"action":"delete-account","password":"correct horse"}"#,
            #"{"confirmation":"you@example.test"}"#,
        ])
        XCTAssertEqual(transport.requests.last?.method, .delete)
        XCTAssertNil(model.failure)
    }

    /// ⛔ TWO-STEP ACCOUNTS ARE ALLOWED, WITH THE CODE (Sean, 2026-11-07). `MFA_REQUIRED` opens
    /// the code field and is not shown as a failure; the next try carries both.
    func testTwoStepVerificationAsksForTheCodeThenSendsItWithThePassword() async {
        let transport = SettingsTransport(responses: [
            (401, #"{"error":"Enter the code from your authenticator app.","code":"MFA_REQUIRED"}"#),
            (200, Self.proof),
        ])
        let model = Harness(transport).model

        model.usePassword()
        model.password = "pw"
        await model.submitPassword()
        XCTAssertEqual(model.step, .password(needsCode: true))
        XCTAssertNil(model.failure, "asking for the code is not a failure")
        XCTAssertFalse(model.canSubmitPassword, "the password went with the first try and is typed again")

        model.password = "pw"
        XCTAssertFalse(model.canSubmitPassword, "the code is required once asked for")
        model.code = " 123456 "
        await model.submitPassword()

        XCTAssertEqual(model.step, .confirm)
        XCTAssertEqual(transport.bodies.last, #"{"action":"delete-account","code":"123456","password":"pw"}"#)
    }

    func testAWrongPasswordAndAWrongCodeSayWhatToDo() async {
        let transport = SettingsTransport(responses: [
            (403, #"{"error":"That password is not correct.","code":"incorrect_password"}"#),
            (401, #"{"error":"Enter the code.","code":"MFA_REQUIRED"}"#),
            (400, #"{"error":"That code is not valid, or it has already been used.","code":"mfa_code_invalid"}"#),
        ])
        let model = Harness(transport).model
        model.usePassword()

        model.password = "nope"
        await model.submitPassword()
        XCTAssertEqual(model.failure?.message, DeleteAccountCopy.errorWrongPassword)
        XCTAssertEqual(model.step, .password(needsCode: false))

        model.password = "pw"
        await model.submitPassword()
        model.password = "pw"
        model.code = "000000"
        await model.submitPassword()
        XCTAssertEqual(model.failure?.message, DeleteAccountCopy.errorWrongCode)
        XCTAssertEqual(model.step, .password(needsCode: true))
        XCTAssertEqual(model.code, "", "a refused code is cleared for the next one")
    }

    /// ⚠️ AN SSO-ONLY ACCOUNT THAT TRIES THE PASSWORD is sent back to the providers, told why.
    func testAnAccountWithNoPasswordIsSentToItsProvider() async {
        let transport = SettingsTransport(responses: [
            (409, #"{"error":"This account has no password.","code":"NO_PASSWORD_SET"}"#),
        ])
        let model = Harness(transport).model
        model.usePassword()
        model.password = "anything"
        await model.submitPassword()

        XCTAssertEqual(model.step, .explain)
        XCTAssertEqual(model.failure?.message, DeleteAccountCopy.errorNoPassword)
    }

    func testTooManyAttemptsAndOfflineAreSaidPlainly() async {
        let limited = Harness(SettingsTransport(responses: [
            (429, #"{"error":"Too many attempts.","code":"rate_limited"}"#),
        ])).model
        limited.usePassword()
        limited.password = "pw"
        await limited.submitPassword()
        XCTAssertEqual(limited.failure?.message, DeleteAccountCopy.errorTooManyAttempts)

        let offline = Harness(OfflineTransport()).model
        offline.usePassword()
        offline.password = "pw"
        await offline.submitPassword()
        XCTAssertEqual(offline.failure?.message, DeleteAccountCopy.errorOfflineNotConfirmed)
        XCTAssertEqual(offline.step, .password(needsCode: false))
    }

    // MARK: - The SSO path

    func testAFreshProviderSignInLeadsToTheTypedEmail() async {
        let harness = Harness(SettingsTransport([]), sso: .proved(expiresInSeconds: 280))
        await harness.model.reauthenticate(with: .microsoft)
        XCTAssertEqual(harness.model.step, .confirm)
        XCTAssertEqual(harness.providers, [.microsoft])
    }

    func testEverySheetOutcomeHasItsSentenceAndCancellingHasNone() async {
        let cases: [(SSOReauthOutcome, String?)] = [
            (.cancelled, nil),
            (.stateMismatch, DeleteAccountCopy.errorSignInNotVerified),
            (.noCode, DeleteAccountCopy.errorSignInNotVerified),
            (.couldNotOpen, DeleteAccountCopy.errorSheetDidNotOpen),
            (.refused(.http(status: 403, message: "x", code: "reauth_failed")), DeleteAccountCopy.errorWrongAccount),
            (.refused(.transport("offline")), DeleteAccountCopy.errorOfflineNotConfirmed),
            (.refused(.http(status: 429, message: "x", code: "rate_limited")), DeleteAccountCopy.errorTooManyAttempts),
        ]
        for (outcome, expected) in cases {
            let model = Harness(SettingsTransport([]), sso: outcome).model
            await model.reauthenticate(with: .google)
            XCTAssertEqual(model.step, .explain, "\(outcome)")
            XCTAssertEqual(model.failure?.message, expected, "\(outcome)")
            XCTAssertFalse(model.busy)
        }
    }

    // MARK: - The last step

    /// ⛔ A TYPO COSTS NOTHING: the service compares the email before it spends the proof, so
    /// the step stays and the person can type it again.
    func testAMistypedEmailStaysOnTheLastStep() async {
        let transport = SettingsTransport(responses: [
            (400, #"{"error":"Type the account's email address to confirm.","code":"confirmation_mismatch"}"#),
            (200, Self.deletedBody),
        ])
        let harness = Harness(transport, sso: .proved(expiresInSeconds: 300))
        await harness.model.reauthenticate(with: .google)
        harness.model.confirmation = "me@example.test"
        await harness.model.delete()

        XCTAssertEqual(harness.model.step, .confirm)
        XCTAssertEqual(harness.model.failure?.message, DeleteAccountCopy.errorEmailMismatch)
        XCTAssertEqual(harness.model.confirmation, "me@example.test", "kept, to be corrected")
        XCTAssertTrue(harness.deletions.isEmpty)

        harness.model.confirmation = "you@example.test"
        await harness.model.delete()
        XCTAssertEqual(harness.deletions, [false])
    }

    func testAnExpiredProofGoesBackToConfirmingItIsYou() async {
        let transport = SettingsTransport(responses: [
            (403, #"{"error":"Confirm it is you again, then delete the account.","code":"reauth_required"}"#),
        ])
        let harness = Harness(transport, sso: .proved(expiresInSeconds: 1))
        await harness.model.reauthenticate(with: .apple)
        harness.model.confirmation = "you@example.test"
        await harness.model.delete()

        XCTAssertEqual(harness.model.step, .explain)
        XCTAssertEqual(harness.model.failure?.message, DeleteAccountCopy.errorProofExpired)
        XCTAssertTrue(harness.deletions.isEmpty)
    }

    /// ⛔ A BLOCK IS THE SERVICE'S ANSWER, SHOWN AS IT COMES, under a headline that says nothing
    /// was deleted. The subscription refusal is the live one.
    func testABlockedDeletionShowsTheServiceReason() async {
        let reason = "Your subscription could not be cancelled, so the account was not deleted. Please try again."
        let transport = SettingsTransport(responses: [
            (503, #"{"error":"\#(reason)","code":"service_unavailable","accountDeleted":false}"#),
            (500, #"{"error":"Internal server error","code":"server_error"}"#),
        ])
        let harness = Harness(transport, sso: .proved(expiresInSeconds: 300))
        await harness.model.reauthenticate(with: .google)
        harness.model.confirmation = "you@example.test"

        await harness.model.delete()
        XCTAssertEqual(harness.model.failure, .init(title: DeleteAccountCopy.notDeleted, message: reason))
        XCTAssertEqual(harness.model.step, .confirm)

        await harness.model.delete()
        XCTAssertEqual(
            harness.model.failure,
            .init(title: DeleteAccountCopy.notDeleted, message: DeleteAccountCopy.errorTryAgainShortly)
        )
        XCTAssertTrue(harness.deletions.isEmpty)
    }

    func testOfflineAndAnUnreadableAnswerNeverClaimADeletion() async {
        let offline = Harness(OfflineTransport(), sso: .proved(expiresInSeconds: 300))
        await offline.model.reauthenticate(with: .google)
        offline.model.confirmation = "you@example.test"
        await offline.model.delete()
        XCTAssertEqual(offline.model.failure?.message, DeleteAccountCopy.errorOfflineOutcomeUnknown)

        let unreadable = Harness(
            SettingsTransport([#"{"success":true}"#]),
            sso: .proved(expiresInSeconds: 300)
        )
        await unreadable.model.reauthenticate(with: .google)
        unreadable.model.confirmation = "you@example.test"
        await unreadable.model.delete()
        XCTAssertEqual(unreadable.model.failure?.message, DeleteAccountCopy.errorOutcomeUnknown)
        XCTAssertTrue(offline.deletions.isEmpty)
        XCTAssertTrue(unreadable.deletions.isEmpty)
    }

    func testVendorErasureStillPendingIsPassedOn() async {
        let pending = #"{"success":true,"accountDeleted":true,"externalErasurePending":true,"message":"x"}"#
        let harness = Harness(SettingsTransport([pending], status: 202), sso: .proved(expiresInSeconds: 300))
        await harness.model.reauthenticate(with: .google)
        harness.model.confirmation = "you@example.test"
        await harness.model.delete()
        XCTAssertEqual(harness.deletions, [true])
    }

    // MARK: - Single flight

    /// ⛔ TWO TAPS BEFORE A RE-RENDER SEND ONE DELETE.
    func testTwoConcurrentDeletesSendOneRequest() async {
        let transport = SettingsTransport(responses: [(200, Self.deletedBody), (200, Self.deletedBody)])
        let harness = Harness(transport, sso: .proved(expiresInSeconds: 300))
        await harness.model.reauthenticate(with: .google)
        harness.model.confirmation = "you@example.test"

        async let first: Void = harness.model.delete()
        async let second: Void = harness.model.delete()
        _ = await (first, second)

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(harness.deletions.count, 1)
    }

    func testTwoConcurrentPasswordTriesSendOne() async {
        let transport = SettingsTransport(responses: [(200, Self.proof), (200, Self.proof)])
        let model = Harness(transport).model
        model.usePassword()
        model.password = "pw"

        async let first: Void = model.submitPassword()
        async let second: Void = model.submitPassword()
        _ = await (first, second)

        XCTAssertEqual(transport.requests.count, 1)
    }

    func testNothingIsSentBeforeTheStepAllowsIt() async {
        let transport = SettingsTransport([Self.deletedBody])
        let harness = Harness(transport, sso: .proved(expiresInSeconds: 300))
        harness.model.confirmation = "you@example.test"
        await harness.model.delete()
        await harness.model.submitPassword()
        XCTAssertTrue(transport.requests.isEmpty, "no delete without a proof, no password without the field")
        XCTAssertFalse(harness.model.canDelete)
    }

    // MARK: - French

    /// ⛔ NO ENGLISH ON A FRENCH SCREEN: a refusal with a code the app does not branch on reads
    /// the core's French sentence, not the service's English.
    func testAFrenchRefusalIsInFrench() {
        let saved = L10nRuntime.locale
        L10nRuntime.locale = .frCA
        defer { L10nRuntime.locale = saved }
        let failure = DeleteAccountModel.deleteFailure(
            .http(status: 503, message: "Your subscription could not be cancelled.", code: "service_unavailable")
        )
        XCTAssertEqual(failure.title, "Votre compte n'a pas été supprimé.")
        XCTAssertFalse(failure.message.contains("subscription"), failure.message)
    }

    // MARK: - Helpers

    private static let proof = #"{"success":true,"action":"delete-account","expiresInSeconds":300}"#
    private static let deletedBody =
        #"{"success":true,"accountDeleted":true,"externalErasurePending":false,"message":"Deleted."}"#

    /// What the model handed its two seams, in order.
    @MainActor
    private final class Recorder {
        var deletions: [Bool] = []
        var providers: [ReauthProvider] = []
    }

    @MainActor
    private struct Harness {
        let model: DeleteAccountModel
        private let recorder: Recorder

        var deletions: [Bool] {
            recorder.deletions
        }

        var providers: [ReauthProvider] {
            recorder.providers
        }

        init(_ transport: any HTTPTransport, sso: SSOReauthOutcome = .cancelled) {
            let recorder = Recorder()
            self.recorder = recorder
            model = DeleteAccountModel(
                repository: NativeReauthRepository(client: ApiClient(
                    baseURL: ApiClient.productionBaseURL,
                    transport: transport,
                    accessToken: { "session-token" }
                )),
                sso: { provider in
                    recorder.providers.append(provider)
                    return sso
                },
                deleted: { pending in recorder.deletions.append(pending) }
            )
        }
    }
}

/// A transport whose every request fails before a response, as offline does.
final class OfflineTransport: HTTPTransport, @unchecked Sendable {
    func send(_ request: HTTPRequest, followRedirects: Bool) async throws -> HTTPResponse {
        _ = (request, followRedirects)
        throw URLError(.notConnectedToInternet)
    }
}
