@testable import DistrictAI
import DistrictData
import SwiftUI
import XCTest

/// The two-step sheet's steps between the overview and the secret: proving it is you, and the
/// password (with and without a code), drawn from the sheet itself.
///
/// ⚠️ THE STEP IS TAKEN AFTER THE SHEET'S OWN STATUS READ HAS LANDED (``firstReadLanded``), in
/// the sheet's task, so the read that puts it on the overview cannot land on top of the step.
final class TwoStepStepsSnapshotTests: ScreenSnapshotTestCase {
    private static let mfaPath = "/api/auth/mfa"

    private func sheet(
        _ container: AppContainer,
        _ step: @escaping @MainActor (TwoStepModel) async -> Void
    ) -> some View {
        let reauth = NativeReauthRepository(client: container.api)
        let model = TwoStepModel(
            settings: TwoStepSettingsRepository(client: container.api),
            reauth: reauth,
            sso: { _ in .cancelled }
        )
        return SnapshotPrepared(TwoStepView(model: model)) {
            await firstReadLanded { model.step == .overview }
            await step(model)
        }
    }

    /// Turning it on starts with proving it is you: a provider or the password.
    func testProveItIsYouToTurnOn() async throws {
        try await assertScreen([Self.mfaPath: .json(TwoStepFixtures.statusOff)]) { container in
            self.sheet(container) { $0.begin(.turnOn) }
        }
    }

    /// Turning it off asks the same, for the other intent.
    func testProveItIsYouToTurnOff() async throws {
        try await assertScreen([Self.mfaPath: .fixture("district-mfa-status")], devices: [.iPhone]) { container in
            self.sheet(container) { $0.begin(.turnOff) }
        }
    }

    /// The password step, empty: the continue button waits for a password.
    func testThePasswordStep() async throws {
        try await assertScreen([Self.mfaPath: .json(TwoStepFixtures.statusOff)], devices: [.iPhone]) { container in
            self.sheet(container) { model in
                model.begin(.turnOn)
                model.usePassword()
            }
        }
    }

    /// The service answered `MFA_REQUIRED`: the step asks for a code beside the password.
    func testThePasswordStepAsksForACode() async throws {
        try await assertScreen(
            [
                Self.mfaPath: .fixture("district-mfa-status"),
                "/api/auth/native/reauth/password": .json(
                    #"{"error":"Enter the code from your authenticator app.","code":"MFA_REQUIRED"}"#,
                    status: 401
                ),
            ],
            devices: [.iPhone]
        ) { container in
            self.sheet(container) { model in
                model.begin(.turnOff)
                model.usePassword()
                model.password = "correct horse"
                await model.submitPassword()
            }
        }
    }
}
