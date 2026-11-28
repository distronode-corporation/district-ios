@testable import DistrictAI
import DistrictData
import DistrictL10n
import DistrictNetwork
import Foundation
import SwiftUI
import XCTest

/// The account's modal sheets: two-step verification, deleting the account and the watch relay's
/// diagnostics, each in the states a person meets them in.
///
/// ⚠️ THE TWO-STEP SHEET READS ITS STATUS AGAIN EVERY TIME IT APPEARS, which puts it back on the
/// overview, so the steps that hold a secret are drawn through their own cards
/// (``TwoStepScanCard``, ``TwoStepCodesCard``) over a model driven there by the real repository.
final class AccountSheetSnapshotTests: ScreenSnapshotTestCase {
    private static let mfaPath = "/api/auth/mfa"

    // MARK: - Two-step verification

    /// On, as the recorded status says: enrolled, seven backup codes left, may be turned off.
    func testTwoStepOn() async throws {
        try await assertScreen([Self.mfaPath: .fixture("district-mfa-status")]) { container in
            TwoStepView(container: container)
        }
    }

    /// Off: the case for turning it on.
    func testTwoStepOff() async throws {
        try await assertScreen([Self.mfaPath: .json(TwoStepFixtures.statusOff)]) { container in
            TwoStepView(container: container)
        }
    }

    /// On for an account that signs in without a password, which may not turn it off here.
    func testTwoStepOnCannotDisable() async throws {
        let status = #"{"enrolled":true,"enrolledAt":"2026-10-01T12:00:00.000Z","backupCodesRemaining":0,"#
            + #""canDisable":false}"#
        try await assertScreen([Self.mfaPath: .json(status)]) { container in
            TwoStepView(container: container)
        }
    }

    /// The first read refused: the reason and Retry, never a guessed status.
    func testTwoStepLoadFailed() async throws {
        try await assertScreen(
            [Self.mfaPath: .json(#"{"error":"Something went wrong.","code":"server_error"}"#, status: 500)]
        ) { container in
            TwoStepView(container: container)
        }
    }

    /// The scan step: the QR code, the key in groups of four and the code field.
    func testTwoStepScanCard() async throws {
        let model = await TwoStepFixtures.scanning(then: [])
        let enrollment = try XCTUnwrap(model.enrollment)
        try await assertScreen(devices: [.iPhone]) { _ in
            ScrollView { TwoStepScanCard(model: model, enrollment: enrollment).padding() }
        }
    }

    /// The recovery codes, shown once after the code is confirmed.
    func testTwoStepRecoveryCodes() async throws {
        let model = await TwoStepFixtures.scanning(then: [
            (200, TwoStepFixtures.confirmed),
            (200, TwoStepFixtures.statusOn),
        ])
        model.totp = "123456"
        await model.confirm()
        XCTAssertEqual(model.step, .recoveryCodes)
        try await assertScreen(devices: [.iPhone]) { _ in
            ScrollView { TwoStepCodesCard(model: model).padding() }
        }
    }

    // MARK: - Deleting the account

    /// What deleting means, and the ways to prove it is you.
    func testDeleteExplain() async throws {
        let model = Self.deleteModel(SettingsTransport([]))
        try await assertScreen { _ in DeleteAccountView(model: model) }
    }

    /// The sign-in sheet would not open: said above the same choices.
    ///
    /// ⚠️ THE FAILURE IS PRODUCED INSIDE EACH DRAWING, after the harness has set its language:
    /// the model stores the sentence when it fails, so a failure made beforehand drew English
    /// in the French reference (CodeRabbit #146).
    func testDeleteExplainSheetDidNotOpen() async throws {
        try await assertScreen(devices: [.iPhone]) { _ in
            let model = Self.deleteModel(SettingsTransport([]), sso: .couldNotOpen)
            return SnapshotPrepared(DeleteAccountView(model: model)) {
                await model.reauthenticate(with: .google)
                XCTAssertNotNil(model.failure)
            }
        }
    }

    /// The password field.
    func testDeletePassword() async throws {
        let model = Self.deleteModel(SettingsTransport([]))
        model.usePassword()
        try await assertScreen(devices: [.iPhone]) { _ in DeleteAccountView(model: model) }
    }

    /// The password again with the authenticator code, after the service answered `MFA_REQUIRED`.
    func testDeletePasswordNeedsCode() async throws {
        let model = Self.deleteModel(SettingsTransport(responses: [
            (401, #"{"error":"Enter the code from your authenticator app.","code":"MFA_REQUIRED"}"#),
        ]))
        model.usePassword()
        model.password = "correct horse"
        await model.submitPassword()
        XCTAssertEqual(model.step, .password(needsCode: true))
        try await assertScreen(devices: [.iPhone]) { _ in DeleteAccountView(model: model) }
    }

    /// A proof held: type the email to delete.
    func testDeleteConfirm() async throws {
        let model = Self.deleteModel(SettingsTransport([]), sso: .proved(expiresInSeconds: 300))
        await model.reauthenticate(with: .google)
        XCTAssertEqual(model.step, .confirm)
        try await assertScreen { _ in DeleteAccountView(model: model) }
    }

    /// The typed email did not match the account's.
    ///
    /// ⛔ ONE MODEL PER LANGUAGE, DRIVEN AFTER THE LANGUAGE IS SET: the model keeps the refusal as
    /// the sentence it was when Delete was pressed, so one model drawn in both languages showed
    /// the English sentence in the French reference (#165).
    func testDeleteConfirmMismatch() async throws {
        for locale in [L10nLocale.en, .frCA] {
            L10nRuntime.locale = locale
            let model = Self.deleteModel(
                SettingsTransport(responses: [
                    (400, #"{"error":"That is not the email on this account.","code":"confirmation_mismatch"}"#),
                ]),
                sso: .proved(expiresInSeconds: 300)
            )
            await model.reauthenticate(with: .google)
            model.confirmation = "someone@example.test"
            await model.delete()
            XCTAssertNotNil(model.failure)
            try await assertScreen(devices: [.iPhone], locales: [locale]) { _ in DeleteAccountView(model: model) }
        }
    }

    private static func deleteModel(
        _ transport: SettingsTransport,
        sso: SSOReauthOutcome = .cancelled
    ) -> DeleteAccountModel {
        DeleteAccountModel(
            repository: NativeReauthRepository(client: ApiClient(
                baseURL: ApiClient.productionBaseURL,
                transport: transport,
                accessToken: { "session-token" }
            )),
            sso: { _ in sso },
            deleted: { _ in }
        )
    }

    // MARK: - Watch relay diagnostics

    /// Not recording, nothing kept.
    func testWatchDiagnosticsIdle() async throws {
        let diagnostics = WatchRelayDiagnostics(defaults: SetupDefaults.fresh(), fileURL: nil)
        try await assertScreen(devices: [.iPhone]) { _ in WatchDiagnosticsView(diagnostics: diagnostics) }
    }

    /// Recording with the socket forced, three entries kept and shareable.
    func testWatchDiagnosticsRecording() async throws {
        let diagnostics = WatchRelayDiagnostics(defaults: SetupDefaults.fresh(), fileURL: nil)
        diagnostics.recording = true
        diagnostics.forceSocket = true
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        diagnostics.record(.request, "inbox", at: at)
        diagnostics.record(.reply, "inbox 120 ms", at: at.addingTimeInterval(0.12))
        diagnostics.record(.socketOpened, at: at.addingTimeInterval(1))
        XCTAssertEqual(diagnostics.entries.count, 3)
        try await assertScreen(devices: [.iPhone]) { _ in WatchDiagnosticsView(diagnostics: diagnostics) }
    }
}
