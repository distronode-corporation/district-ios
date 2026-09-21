@testable import DistrictAI
import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// Profile, notifications, branding, the three automation toggles, and the three
/// image uploads.
///
/// ⛔ THE UPLOAD ASSERTIONS READ THE MULTIPART HEADERS, NOT THE ARGUMENTS. The part
/// is named `file` on OUR hop and is renamed per-target at the far end; a part named
/// after the target is "file_required" before the scheduler is ever asked, and
/// nothing between here and production would catch it.
@MainActor
final class SchedulingWritesBSettingsTests: XCTestCase {
    private typealias Fixtures = SchedulingWritesBFixtures

    // MARK: - Profile

    /// ⛔ FIVE KEYS, AND `timezone` RATHER THAN `iana_timezone`. The column name is
    /// silently IGNORED by the fork, which would leave every window this member
    /// publishes on whatever zone the SSO hand-off inserted.
    func testSavingTheProfileSendsTheFiveFieldsUnderTheWireNames() async throws {
        let transport = SettingsTransport([Fixtures.ok(Fixtures.me)])
        let model = try Self.profileModel(transport)
        model.editName("  Ada Lovelace  ")
        model.editTimezone("Europe/Tallinn")
        model.editTimeFormat("24h")
        model.editWeekStart(1)
        model.editDateFormat("dmy")
        await model.save()

        XCTAssertEqual(Fixtures.op(transport), "me.patch")
        let params = Fixtures.params(transport)
        XCTAssertEqual(params["name"] as? String, "Ada Lovelace")
        XCTAssertEqual(params["timezone"] as? String, "Europe/Tallinn")
        XCTAssertEqual(params["time_format"] as? String, "24h")
        XCTAssertEqual(params["week_start"] as? Int, 1)
        XCTAssertEqual(params["date_format"] as? String, "dmy")
        XCTAssertNil(params["iana_timezone"])
        XCTAssertEqual(params.count, 5)
        XCTAssertEqual(Fixtures.done(model.state), SchedulingSettingsWriteCopy.profileDone)
    }

    func testTheProfileRefusesEachInvalidFieldWithTheWebsOwnSentence() async throws {
        let cases: [(String, (SchedulingProfileModel) -> Void)] = [
            (SchedulingSettingsWriteCopy.nameRequired, { $0.editName("  ") }),
            (SchedulingSettingsWriteCopy.timezoneRequired, { $0.editTimezone("") }),
            (SchedulingSettingsWriteCopy.timeFormatRequired, { $0.editTimeFormat("am-pm") }),
            (SchedulingSettingsWriteCopy.weekStartRequired, { $0.editWeekStart(9) }),
            (SchedulingSettingsWriteCopy.dateFormatRequired, { $0.editDateFormat("iso") }),
        ]
        for (sentence, mutate) in cases {
            let transport = SettingsTransport([])
            let model = try Self.profileModel(transport)
            mutate(model)
            await model.save()

            XCTAssertTrue(transport.requests.isEmpty, "\(sentence) should spend no request")
            XCTAssertEqual(model.rejected, sentence)
        }
    }

    /// ⛔ THE STORED ZONE IS ALWAYS AN OPTION. A picker that dropped a zone the
    /// device does not know would rewrite it on the next save.
    func testTheTimezonePickerAlwaysOffersTheZoneAlreadyStored() throws {
        let transport = SettingsTransport([])
        let model = try Self.profileModel(transport)
        model.editTimezone("Mars/Olympus")

        XCTAssertEqual(model.timezoneOptions.first, "Mars/Olympus")
    }

    /// ⛔ THE PART IS `file`, THE TARGET TRAVELS AS ITS OWN FIELD, AND THE FILENAME
    /// IS PRESENT — without a filename the part is a plain field, `file instanceof
    /// File` fails and the route answers 400.
    func testUploadingAnAvatarSendsAFilePartAndAnAvatarTarget() async throws {
        let uploads = SettingsTransport(["{\"ok\":true,\"data\":{\"avatar_url\":\"https://x/new.png\"}}"])
        let model = try Self.profileModel(SettingsTransport([]), media: uploads)
        await model.uploadAvatar(bytes: Data("PNGBYTES".utf8), mimeType: "image/png")

        let body = Fixtures.multipart(uploads)
        XCTAssertTrue(body.contains("name=\"file\""), body)
        XCTAssertTrue(body.contains("name=\"target\""), body)
        XCTAssertTrue(body.contains("avatar"), body)
        XCTAssertTrue(body.contains("filename="), body)
        XCTAssertTrue(body.contains("Content-Type: image/png"), body)
        XCTAssertEqual(model.avatarUrl, "https://x/new.png")
    }

    /// ⛔ SVG IS THE ONE AN OPERATOR WILL WANT FOR A LOGO AND IT IS A SCRIPT-BEARING
    /// DOCUMENT. The route refuses it with a 415 that lands on the honest generic, so
    /// the better message has to be bought on the way IN.
    func testAnUnacceptableImageIsRefusedBeforeAnyRequestIsSpent() async throws {
        let uploads = SettingsTransport([])
        let model = try Self.profileModel(SettingsTransport([]), media: uploads)
        await model.uploadAvatar(bytes: Data("<svg/>".utf8), mimeType: "image/svg+xml")

        XCTAssertTrue(uploads.requests.isEmpty)
        XCTAssertEqual(Fixtures.failure(model.avatarState), SchedulingSettingsWriteCopy.imageWrongType)
    }

    func testAnOversizedImageIsRefusedBeforeAnyRequestIsSpent() async throws {
        let uploads = SettingsTransport([])
        let model = try Self.profileModel(SettingsTransport([]), media: uploads)
        let tooBig = Data(count: SchedulingUploadFile.maxBytes + 1)
        await model.uploadAvatar(bytes: tooBig, mimeType: "image/png")

        XCTAssertTrue(uploads.requests.isEmpty)
        XCTAssertEqual(Fixtures.failure(model.avatarState), SchedulingSettingsWriteCopy.imageTooLarge)
    }

    /// ⚠️ THE DELETE ANSWERS NOTHING, so the URL this model holds is stale on return
    /// and `me.get` is the only way to learn the new one.
    func testDeletingTheAvatarReReadsTheProfile() async throws {
        let transport = SettingsTransport([Fixtures.noContent, Fixtures.ok(Fixtures.me)])
        let model = try Self.profileModel(transport)
        await model.deleteAvatar()

        XCTAssertEqual(Fixtures.op(transport), "me.avatar.delete")
        XCTAssertEqual(Fixtures.op(transport, 1), "me.get")
    }

    // MARK: - Notifications

    /// ⚠️ ALL SEVEN, AND NONE OF THE PROFILE'S FIVE. `me.patch` is sparse, which is
    /// what makes two forms over one op safe — and what this assertion protects.
    func testNotificationsSendOnlyTheSevenNotifyKeys() async throws {
        let transport = SettingsTransport([Fixtures.ok(Fixtures.me)])
        let model = try SchedulingNotificationsModel(
            admin: Fixtures.repository(transport),
            workspaceId: Fixtures.workspaceId,
            me: Self.me(),
            onSaved: { _ in }
        )
        model.editHostCancel(true)
        await model.save()

        XCTAssertEqual(Fixtures.op(transport), "me.patch")
        let params = Fixtures.params(transport)
        XCTAssertEqual(params.count, 7)
        XCTAssertNil(params["name"])
        XCTAssertNil(params["timezone"])
        XCTAssertEqual(params["notify_host_cancel"] as? Bool, true)
        XCTAssertEqual(params["notify_reminder"] as? Bool, false)
        XCTAssertEqual(Fixtures.done(model.state), SchedulingSettingsWriteCopy.notificationsDone)
    }

    // MARK: - Branding

    /// ⛔ ALL SEVEN FIELDS EVERY TIME, AND NEITHER IMAGE URL. The fork decodes into
    /// non-pointer fields, so an omitted `privacy_url` CLEARS the customer's privacy
    /// link; `logo_url` is not in the patch schema at all.
    func testSavingBrandingSendsTheSevenRequiredFieldsAndNoImageUrls() async throws {
        let transport = SettingsTransport([Fixtures.ok(Fixtures.branding)])
        let model = try Self.brandingModel(transport)
        await model.save()

        XCTAssertEqual(Fixtures.op(transport), "settings.branding.patch")
        let params = Fixtures.params(transport)
        XCTAssertEqual(params.count, 7)
        XCTAssertEqual(params["business_name"] as? String, "Acme")
        XCTAssertEqual(params["logo_height"] as? Int, 32)
        XCTAssertEqual(params["privacy_url"] as? String, "https://acme.test/privacy")
        // ⚠️ `""` IS THE LEGITIMATE "no link" VALUE and is sent, not dropped.
        XCTAssertEqual(params["terms_url"] as? String, "")
        XCTAssertNil(params["logo_url"])
        XCTAssertNil(params["banner_url"])
        XCTAssertEqual(Fixtures.done(model.state), SchedulingSettingsWriteCopy.brandingDone)
    }

    /// ⛔ `URL(string:)` ALONE IS NOT THE CHECK — it accepts a bare `example.com` —
    /// so the scheme is tested explicitly, which is what makes "starting with
    /// https://" a true sentence.
    func testALegalLinkMustBeAbsoluteOrEmpty() {
        XCTAssertNil(SchedulingBrandingModel.urlFailure(""))
        XCTAssertNil(SchedulingBrandingModel.urlFailure("   "))
        XCTAssertNil(SchedulingBrandingModel.urlFailure("https://acme.test/privacy"))
        XCTAssertEqual(
            SchedulingBrandingModel.urlFailure("acme.test/privacy"),
            SchedulingSettingsWriteCopy.urlNotAbsolute
        )
        XCTAssertEqual(
            SchedulingBrandingModel.urlFailure("javascript:alert(1)"),
            SchedulingSettingsWriteCopy.urlNotAbsolute
        )
        XCTAssertEqual(
            SchedulingBrandingModel.urlFailure("https://acme.test/" + String(repeating: "p", count: 600)),
            SchedulingSettingsWriteCopy.urlTooLong
        )
    }

    func testBrandingRefusesAnOutOfRangeLogoHeightBeforeAnyRequest() async throws {
        let transport = SettingsTransport([])
        let model = try Self.brandingModel(transport)
        model.editLogoHeight(4)
        await model.save()

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(model.rejected, SchedulingSettingsWriteCopy.wholeNumberBetween(16, 64))
    }

    /// ⛔ THE UPLOAD RE-READS THE BRANDING, because the answer's one key can
    /// legitimately be `""` — "uploaded, address unreadable".
    func testUploadingALogoSendsTheLogoTargetAndThenReReadsTheBranding() async throws {
        let rpc = SettingsTransport([Fixtures.ok(Fixtures.branding)])
        let uploads = SettingsTransport(["{\"ok\":true,\"data\":{\"logo_url\":\"https://x/l2.png\"}}"])
        let model = try Self.brandingModel(rpc, media: uploads)
        await model.upload(bytes: Data("PNGBYTES".utf8), mimeType: "image/png", target: .logo)

        let body = Fixtures.multipart(uploads)
        XCTAssertTrue(body.contains("name=\"file\""), body)
        XCTAssertTrue(body.contains("logo"), body)
        XCTAssertEqual(Fixtures.op(rpc), "settings.branding.get")
        XCTAssertEqual(
            Fixtures.done(model.logoState),
            SchedulingSettingsWriteCopy.imageUploaded(SchedulingSettingsWriteCopy.logoLabel)
        )
    }

    /// ⚠️ THE ONLY WAY TO CLEAR AN IMAGE. `logo_url` is absent from the patch schema,
    /// so an empty string there is a 400 naming a field that does not exist.
    func testRemovingTheBannerUsesItsOwnDeleteOp() async throws {
        let transport = SettingsTransport([Fixtures.noContent, Fixtures.ok(Fixtures.branding)])
        let model = try Self.brandingModel(transport)
        await model.removeImage(.banner)

        XCTAssertEqual(Fixtures.op(transport), "settings.branding.banner.delete")
        XCTAssertEqual(Fixtures.op(transport, 1), "settings.branding.get")
    }

    // MARK: - Automation

    /// ⛔ ONLY THE CHANGED SECTIONS ARE SENT. Each is a separate write against the
    /// workspace's 120-an-hour budget, and `settings.llm.patch` with neither field is
    /// a valid no-op the server would accept without objecting.
    func testOnlyTheSectionsThatChangedAreWritten() async throws {
        let transport = SettingsTransport([Fixtures.ok(Fixtures.notetaker(true))])
        let model = try Self.automationModel(transport)
        model.editNotetaker(true)
        await model.save()

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(Fixtures.op(transport), "settings.notetaker.patch")
        XCTAssertEqual(Fixtures.params(transport)["enabled"] as? Bool, true)
        // ⛔ `enabled`, NOT `notetaker_enabled`, and the schema is `z.strictObject`.
        XCTAssertEqual(Fixtures.params(transport).count, 1)
        XCTAssertEqual(Fixtures.done(model.state), SchedulingSettingsWriteCopy.automationDone)
    }

    func testNothingIsSentWhenNothingChanged() async throws {
        let transport = SettingsTransport([])
        let model = try Self.automationModel(transport)
        await model.save()

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertFalse(model.isDirty)
    }

    /// ⛔ THE RECORDING TOGGLE CANNOT BE TURNED ON WITHOUT STORAGE. Turning it on
    /// there succeeds and records nothing, which is the wrong answer a customer
    /// finds out about later.
    func testRecordingsCannotBeEnabledWhileTheRegionHasNoStorage() async throws {
        let transport = SettingsTransport([])
        let model = try Self.automationModel(transport, ready: false)
        model.editRecordings(true)

        XCTAssertFalse(model.canEnableRecordings)
        XCTAssertFalse(model.recordingsEnabled)
        XCTAssertEqual(model.recordingsHint, SchedulingSettingsWriteCopy.recordingsNotReadyHint)
        await model.save()
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testTheAssistantInstructionsCeilingIsEnforcedBeforeAnyRequest() async throws {
        let transport = SettingsTransport([])
        let model = try Self.automationModel(transport)
        let limit = SchedulingSettingsWriteCopy.assistantInstructionsLimit
        model.editInstructions(String(repeating: "i", count: limit + 1))
        await model.save()

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(model.rejected, SchedulingSettingsWriteCopy.assistantInstructionsTooLong)
    }

    /// ⚠️ AN EMPTIED BOX REALLY DOES CLEAR THE INSTRUCTIONS. `""` clears and nil
    /// leaves alone; this form always has a string, so the clear is expressible.
    func testEmptyingTheInstructionsSendsAnEmptyStringRatherThanOmittingTheKey() async throws {
        let transport = SettingsTransport([Fixtures.ok(Fixtures.llm(enabled: true, instructions: ""))])
        let model = try Self.automationModel(transport, instructions: "be brief")
        model.editInstructions("")
        await model.save()

        XCTAssertEqual(Fixtures.op(transport), "settings.llm.patch")
        XCTAssertEqual(Fixtures.params(transport)["extra_instructions"] as? String, "")
        XCTAssertEqual(Fixtures.params(transport)["enabled"] as? Bool, true)
    }

    // MARK: - Fixtures

    private static func me() throws -> SchedulingMe {
        try JSONDecoder().decode(SchedulingMe.self, from: Data(SchedulingWritesBFixtures.me.utf8))
    }

    private static func profileModel(
        _ transport: SettingsTransport,
        media: SettingsTransport? = nil
    ) throws -> SchedulingProfileModel {
        try SchedulingProfileModel(
            admin: SchedulingWritesBFixtures.repository(transport),
            media: SchedulingWritesBFixtures.media(media ?? transport),
            workspaceId: SchedulingWritesBFixtures.workspaceId,
            me: me(),
            onSaved: { _ in }
        )
    }

    private static func brandingModel(
        _ transport: SettingsTransport,
        media: SettingsTransport? = nil
    ) throws -> SchedulingBrandingModel {
        let branding = try JSONDecoder().decode(
            SchedulingBranding.self,
            from: Data(SchedulingWritesBFixtures.branding.utf8)
        )
        return SchedulingBrandingModel(
            admin: SchedulingWritesBFixtures.repository(transport),
            media: SchedulingWritesBFixtures.media(media ?? transport),
            workspaceId: SchedulingWritesBFixtures.workspaceId,
            branding: branding,
            onSaved: { _ in }
        )
    }

    private static func automationModel(
        _ transport: SettingsTransport,
        ready: Bool = true,
        instructions: String = ""
    ) throws -> SchedulingAutomationModel {
        let decoder = JSONDecoder()
        let storage = try decoder.decode(
            SchedulingStorageSettings.self,
            from: Data(SchedulingWritesBFixtures.storage(enabled: false, ready: ready).utf8)
        )
        let notetaker = try decoder.decode(
            SchedulingNotetakerSettings.self,
            from: Data(SchedulingWritesBFixtures.notetaker(false).utf8)
        )
        let llm = try decoder.decode(
            SchedulingLLMSettings.self,
            from: Data(SchedulingWritesBFixtures.llm(enabled: true, instructions: instructions).utf8)
        )
        return SchedulingAutomationModel(
            admin: SchedulingWritesBFixtures.repository(transport),
            workspaceId: SchedulingWritesBFixtures.workspaceId,
            storage: storage,
            notetaker: notetaker,
            llm: llm,
            onSaved: {}
        )
    }
}
