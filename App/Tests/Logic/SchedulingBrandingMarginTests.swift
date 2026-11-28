@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// ``SchedulingBrandingModel`` past the happy paths SchedulingWritesBSettingsTests already pins:
/// every validation sentence in its order, a refused save, the image guards (avatar, empty,
/// oversized, wrong type), a failed upload or delete, and a re-read that fails after a write
/// that landed.
@MainActor
final class SchedulingBrandingMarginTests: XCTestCase {
    private typealias Fixtures = SchedulingWritesBFixtures

    private final class SavedLog {
        var rows: [SchedulingBranding] = []
    }

    private func model(
        _ transport: SettingsTransport,
        media: SettingsTransport? = nil,
        log: SavedLog = SavedLog(),
        json: String = SchedulingWritesBFixtures.branding
    ) throws -> SchedulingBrandingModel {
        let branding = try JSONDecoder().decode(SchedulingBranding.self, from: Data(json.utf8))
        return SchedulingBrandingModel(
            admin: Fixtures.repository(transport),
            media: Fixtures.media(media ?? transport),
            workspaceId: Fixtures.workspaceId,
            branding: branding,
            onSaved: { log.rows.append($0) }
        )
    }

    // MARK: - What the form shows

    /// An empty banner address is "no banner", not an image at `""`.
    func testAnEmptyImageAddressIsNoImage() throws {
        let model = try model(SettingsTransport([]))
        XCTAssertEqual(model.logoUrl, "https://x/l.png")
        XCTAssertNil(model.bannerUrl)
        XCTAssertEqual(model.localeOptions.map(\.code), ["en"])
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.validationFailure)
    }

    /// No `supported_locales` from the server leaves no options, rather than a list invented here.
    func testAnAbsentLocaleListOffersNothing() throws {
        let json = """
        {"business_name":"","logo_url":"","logo_height":32,"logo_opacity":100,
        "banner_url":"https://x/b.png","banner_opacity":60,"privacy_url":"",
        "terms_url":"","fallback_locale":"en"}
        """
        let model = try model(SettingsTransport([]), json: json)
        XCTAssertTrue(model.localeOptions.isEmpty)
        XCTAssertNil(model.logoUrl)
        XCTAssertEqual(model.bannerUrl, "https://x/b.png")
    }

    // MARK: - Validation, in the web's order

    func testEachInvalidFieldIsRefusedWithItsSentenceAndNoRequest() async throws {
        let opacities = SchedulingSettingsWriteCopy.wholeNumberBetween(20, 100)
        let tooLong = String(repeating: "n", count: 201)
        let cases: [(String, (SchedulingBrandingModel) -> Void)] = [
            (SchedulingSettingsWriteCopy.businessNameTooLong, { $0.editBusinessName(tooLong) }),
            (SchedulingSettingsWriteCopy.wholeNumberBetween(16, 64), { $0.editLogoHeight(65) }),
            (opacities, { $0.editLogoOpacity(19) }),
            (opacities, { $0.editBannerOpacity(101) }),
            (SchedulingSettingsWriteCopy.urlNotAbsolute, { $0.editPrivacyUrl("ftp://acme.test/p") }),
            (SchedulingSettingsWriteCopy.urlNotAbsolute, { $0.editTermsUrl("https://") }),
            (SchedulingSettingsWriteCopy.fallbackLocaleRequired, { $0.editFallbackLocale("  \n") }),
        ]
        for (sentence, mutate) in cases {
            let transport = SettingsTransport([])
            let model = try model(transport)
            mutate(model)
            XCTAssertEqual(model.validationFailure, sentence)
            await model.save()
            XCTAssertEqual(model.rejected, sentence)
            XCTAssertTrue(transport.requests.isEmpty, "\(sentence) should spend no request")
        }
    }

    /// The limits are inclusive: exactly 200 characters, 16, 64, 20 and 100 all pass.
    func testTheBoundariesThemselvesAreAccepted() throws {
        let model = try model(SettingsTransport([]))
        model.editBusinessName("  " + String(repeating: "n", count: 200) + "  ")
        model.editLogoHeight(16)
        model.editLogoOpacity(20)
        model.editBannerOpacity(100)
        XCTAssertNil(model.validationFailure)
        model.editLogoHeight(64)
        XCTAssertNil(model.validationFailure)
    }

    /// Typing after a refusal clears the sentence, and after a failed save puts the state back to idle.
    func testEditingClearsARejectionAndAFailure() async throws {
        let transport = SettingsTransport([Fixtures.refusal("scheduler_unavailable")])
        let log = SavedLog()
        let model = try model(transport, log: log)
        model.editLogoHeight(2)
        await model.save()
        XCTAssertNotNil(model.rejected)
        model.editLogoHeight(40)
        XCTAssertNil(model.rejected)

        await model.save()
        XCTAssertNotNil(Fixtures.failure(model.state))
        XCTAssertTrue(log.rows.isEmpty, "a refused save must not report a saved row")
        XCTAssertEqual(model.logoHeight, 40, "a refused save keeps the edit")
        model.editTermsUrl("https://acme.test/terms")
        guard case .idle = model.state else { return XCTFail("expected idle, got \(model.state)") }
    }

    /// The saved row is the server's answer, handed to the owner of the sheet.
    func testASavedRowIsAdoptedAndReported() async throws {
        let echo = Fixtures.branding.replacingOccurrences(of: "\"Acme\"", with: "\"Acme Ltd\"")
        let transport = SettingsTransport([Fixtures.ok(echo)])
        let log = SavedLog()
        let model = try model(transport, log: log)
        model.editBusinessName("  Acme Ltd ")
        model.editFallbackLocale("fr")
        await model.save()
        XCTAssertEqual(Fixtures.params(transport)["business_name"] as? String, "Acme Ltd")
        XCTAssertEqual(Fixtures.params(transport)["fallback_locale"] as? String, "fr")
        XCTAssertEqual(model.branding.businessName, "Acme Ltd")
        XCTAssertEqual(log.rows.map(\.businessName), ["Acme Ltd"])
    }

    // MARK: - Images

    /// The avatar belongs to the profile sheet: every image call here refuses it without a request.
    func testTheAvatarTargetIsRefusedEverywhere() async throws {
        let transport = SettingsTransport([])
        let model = try model(transport)
        await model.upload(bytes: Data("PNG".utf8), mimeType: "image/png", target: .avatar)
        await model.removeImage(.avatar)
        model.reportUnreadable(.avatar)
        XCTAssertTrue(transport.requests.isEmpty)
        guard case .idle = model.logoState, case .idle = model.bannerState else {
            return XCTFail("the avatar must not move either image's state")
        }
    }

    func testAnImageIsRefusedOnTheDeviceForEmptyOversizedOrWrongType() async throws {
        struct Pick {
            let bytes: Data
            let mime: String
            let target: SchedulingAdminUploadTarget
            let sentence: String
        }
        let oversized = Data(count: SchedulingUploadFile.maxBytes + 1)
        let cases = [
            Pick(
                bytes: Data(),
                mime: "image/png",
                target: .logo,
                sentence: SchedulingSettingsWriteCopy.imageUnreadable
            ),
            Pick(
                bytes: oversized,
                mime: "image/svg+xml",
                target: .banner,
                sentence: SchedulingSettingsWriteCopy.imageTooLarge
            ),
            Pick(
                bytes: Data("GIF89a".utf8),
                mime: "image/svg+xml",
                target: .logo,
                sentence: SchedulingSettingsWriteCopy.imageWrongType
            ),
        ]
        for pick in cases {
            let transport = SettingsTransport([])
            let model = try model(transport)
            await model.upload(bytes: pick.bytes, mimeType: pick.mime, target: pick.target)
            let state = pick.target == .logo ? model.logoState : model.bannerState
            XCTAssertEqual(Fixtures.failure(state), pick.sentence)
            XCTAssertTrue(transport.requests.isEmpty)
        }
    }

    func testAnUnreadablePickIsReportedOnItsOwnImage() throws {
        let model = try model(SettingsTransport([]))
        model.reportUnreadable(.banner)
        XCTAssertEqual(Fixtures.failure(model.bannerState), SchedulingSettingsWriteCopy.imageUnreadable)
        guard case .idle = model.logoState else { return XCTFail("the logo must stay idle") }
    }

    /// A refused upload says so and leaves the row and the saved callback alone.
    func testAFailedUploadIsAFailureOnThatImage() async throws {
        let rpc = SettingsTransport([])
        let uploads = SettingsTransport([])
        let log = SavedLog()
        let model = try model(rpc, media: uploads, log: log)
        await model.upload(bytes: Data("PNGBYTES".utf8), mimeType: "image/png", target: .banner)
        XCTAssertNotNil(Fixtures.failure(model.bannerState))
        XCTAssertEqual(uploads.requests.count, 1)
        XCTAssertTrue(rpc.requests.isEmpty, "no re-read after a refused upload")
        XCTAssertTrue(log.rows.isEmpty)
    }

    /// The write landed but the re-read failed: the image is done and the old row stays.
    func testAFailedReReadAfterAnUploadKeepsTheOldRow() async throws {
        let rpc = SettingsTransport([])
        let uploads = SettingsTransport([Fixtures.ok("{\"banner_url\":\"\"}")])
        let log = SavedLog()
        let model = try model(rpc, media: uploads, log: log)
        await model.upload(bytes: Data("JPEG".utf8), mimeType: "image/jpeg", target: .banner)
        XCTAssertEqual(
            Fixtures.done(model.bannerState),
            SchedulingSettingsWriteCopy.imageUploaded(SchedulingSettingsWriteCopy.bannerLabel)
        )
        XCTAssertEqual(Fixtures.op(rpc), "settings.branding.get")
        XCTAssertNil(model.bannerUrl)
        XCTAssertTrue(log.rows.isEmpty)
    }

    /// Removing the logo uses the logo's own op and adopts the re-read row, not the form's drafts.
    func testRemovingTheLogoAdoptsTheReReadRowAndKeepsTheDrafts() async throws {
        let fresh = Fixtures.branding
            .replacingOccurrences(of: "\"https://x/l.png\"", with: "\"\"")
            .replacingOccurrences(of: "\"Acme\"", with: "\"Server name\"")
        let transport = SettingsTransport([Fixtures.noContent, Fixtures.ok(fresh)])
        let log = SavedLog()
        let model = try model(transport, log: log)
        model.editBusinessName("Typing in progress")
        await model.removeImage(.logo)
        XCTAssertEqual(Fixtures.op(transport), "settings.branding.logo.delete")
        XCTAssertNil(model.logoUrl)
        XCTAssertEqual(model.businessName, "Typing in progress")
        XCTAssertEqual(log.rows.count, 1)
        XCTAssertEqual(
            Fixtures.done(model.logoState),
            SchedulingSettingsWriteCopy.imageRemoved(SchedulingSettingsWriteCopy.logoLabel)
        )
    }

    func testARefusedDeleteIsAFailureWithNoReRead() async throws {
        let transport = SettingsTransport([Fixtures.refusal("scheduler_unavailable")])
        let model = try model(transport)
        await model.removeImage(.logo)
        XCTAssertNotNil(Fixtures.failure(model.logoState))
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(model.logoUrl, "https://x/l.png")
    }
}
