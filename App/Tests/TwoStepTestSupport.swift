@testable import DistrictAI
import DistrictData
import DistrictL10n
import DistrictModel
import DistrictNetwork
import Foundation
import UIKit
import XCTest

/// The canned answers and the harness both two-step test classes drive.
@MainActor
enum TwoStepFixtures {
    /// A 1x1 PNG, standing in for the service's QR code.
    static let pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGNgAAAAAgABSK+kcQAAAABJRU5ErkJggg=="
    static let statusOn =
        #"{"enrolled":true,"enrolledAt":"2026-10-01T12:00:00.000Z","backupCodesRemaining":7,"canDisable":true}"#
    static let statusOff = #"{"enrolled":false,"enrolledAt":null,"backupCodesRemaining":0,"canDisable":true}"#
    static let proof = #"{"success":true,"action":"2fa-change","expiresInSeconds":300}"#
    static let confirmed = #"{"enrolled":true,"backupCodes":["aaaa-bbbb","cccc-dddd"]}"#
    static var enrolled: String {
        #"{"secret":"JBSWY3DPEHPK3PXP","otpauthUri":"otpauth://totp/Distronode%3Ayou%40example.test?secret=JBSWY3DPEHPK3PXP&issuer=Distronode","qrDataUrl":"data:image/png;base64,"#
            + pixel + #""}"#
    }

    /// A model on the scan step, with `then` queued behind the three answers that got it there.
    static func scanning(then: [(status: Int, body: String)]) async -> TwoStepModel {
        let model =
            TwoStepHarness(SettingsTransport(responses: [(200, statusOff), (200, proof), (200, enrolled)] + then))
                .model
        await drive(model, toScanWith: "pw")
        return model
    }

    static func drive(_ model: TwoStepModel, toScanWith password: String) async {
        await model.load()
        model.begin(.turnOn)
        model.usePassword()
        model.password = password
        await model.submitPassword()
        XCTAssertEqual(model.step, .scan)
    }
}

/// What the model handed its SSO seam, in order.
@MainActor
final class TwoStepRecorder {
    var providers: [ReauthProvider] = []
}

@MainActor
struct TwoStepHarness {
    let model: TwoStepModel
    private let recorder: TwoStepRecorder

    var providers: [ReauthProvider] {
        recorder.providers
    }

    init(_ transport: any HTTPTransport, sso: SSOReauthOutcome = .cancelled) {
        let recorder = TwoStepRecorder()
        self.recorder = recorder
        let client = ApiClient(
            baseURL: ApiClient.productionBaseURL,
            transport: transport,
            accessToken: { "session-token" }
        )
        model = TwoStepModel(
            settings: TwoStepSettingsRepository(client: client),
            reauth: NativeReauthRepository(client: client),
            sso: { provider in
                recorder.providers.append(provider)
                // ⚠️ A SUSPENSION, as the real sheet has, so a second tap can interleave.
                await Task.yield()
                return sso
            }
        )
    }
}
