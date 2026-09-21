import DistrictModel
import Foundation
import XCTest

/// The `me.*` and `settings.*` row DTOs.
///
/// ⛔ INLINE BYTES RATHER THAN THE CONTRACT FIXTURES, WHICH IS THE DIVISION OF
/// LABOUR AND NOT A SHORTCUT. `ImplementedFixtures+SchedulingC.swift` runs the
/// committed corpus through `StrictDecodeVerifier`, which pins the SHAPE — every
/// key modelled, none invented — and cannot pin a branch the fixture does not
/// happen to contain. These tests are the other half: the absent-key polarity of
/// every Optional, and the two `CodingKeys` maps that a rename would break
/// silently because the wire spelling is a string.
final class SchedulingAdminSettingsTests: XCTestCase {
    private let decoder = JSONDecoder()

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }

    // MARK: - The caller's own account

    /// Every key the fork sends, mapped. ⛔ Asserted field by field rather than by
    /// round-tripping: a `CodingKeys` entry pointing at the wrong snake_case string
    /// decodes to nil or throws, and the only thing that catches the FIRST of those
    /// is reading the value back out.
    func testMeMapsEverySnakeCaseKey() throws {
        let me = try decode(SchedulingMe.self, Self.fullMe)
        XCTAssertEqual(me.id, "sched-user-contract")
        XCTAssertEqual(me.email, "contract@distronode.test")
        XCTAssertEqual(me.name, "Contract Member")
        XCTAssertEqual(me.timezone, "America/Toronto")
        XCTAssertEqual(me.timeFormat, "24h")
        XCTAssertEqual(me.weekStart, 1)
        XCTAssertEqual(me.dateFormat, "ymd")
        XCTAssertTrue(me.isAdmin)
        XCTAssertFalse(me.isOwner)
        XCTAssertEqual(me.role, "admin")
        XCTAssertTrue(me.notifyConfirmation)
        XCTAssertTrue(me.notifyCancellation)
        XCTAssertFalse(me.notifyReschedule)
        XCTAssertTrue(me.notifyReminder)
        XCTAssertTrue(me.notifyHostBooking)
        XCTAssertFalse(me.notifyHostCancel)
        XCTAssertTrue(me.notifyHostReschedule)
        XCTAssertEqual(me.avatarUrl, "https://book.test/avatars/contract.png")
    }

    /// ⛔ THE AVATAR KEY IS ABSENT, NOT NULL, FOR A MEMBER WHO NEVER UPLOADED ONE.
    /// The catalog types it `.optional()` and the fork omits it; an explicit null
    /// would be a shape the register would have to sanction, and it is not one the
    /// server sends.
    func testMeSurvivesAnAbsentAvatar() throws {
        let me = try decode(SchedulingMe.self, Self.meWithoutAvatar)
        XCTAssertNil(me.avatarUrl)
        XCTAssertEqual(me.id, "sched-user-contract")
    }

    /// ⚠️ THE SEVENTEEN OTHER FIELDS ARE REQUIRED AND A MISSING ONE THROWS. Stated
    /// as a test because "make it Optional" is the reflex fix for a decode failure,
    /// and on this row it would hide a fork that stopped sending a preference the
    /// screen then silently renders as off.
    func testMeRefusesABodyMissingARequiredPreference() {
        XCTAssertThrowsError(try decode(SchedulingMe.self, Self.fullMe.replacingOccurrences(
            of: #""notify_host_cancel":false,"#,
            with: ""
        )))
    }

    // MARK: - Branding

    func testBrandingMapsEveryKeyIncludingTheLocaleTable() throws {
        let branding = try decode(SchedulingBranding.self, Self.fullBranding)
        XCTAssertEqual(branding.businessName, "Contract Agency")
        XCTAssertEqual(branding.logoUrl, "https://book.test/branding/logo.png")
        XCTAssertEqual(branding.logoHeight, 48)
        XCTAssertEqual(branding.logoOpacity, 100)
        XCTAssertEqual(branding.bannerUrl, "https://book.test/branding/banner.png")
        XCTAssertEqual(branding.bannerOpacity, 80)
        XCTAssertEqual(branding.termsUrl, "https://www.contract.test/terms")
        XCTAssertEqual(branding.fallbackLocale, "en")
        XCTAssertEqual(branding.supportedLocales?.map(\.code), ["en", "fr"])
        XCTAssertEqual(branding.supportedLocales?.map(\.name), ["English", "Français"])
    }

    /// ⛔ `""` IS THE ORDINARY VALUE FOR AN UNSET LINK AND NOT A MISSING KEY. The
    /// schema types `privacy_url` a required `z.string()`, so emptiness is the "no
    /// link" test — an Optional here would model a shape the server never sends,
    /// and a screen testing for nil would render a link to nowhere.
    func testAnUnsetBrandingLinkIsAnEmptyStringRatherThanAnAbsentKey() throws {
        XCTAssertEqual(try decode(SchedulingBranding.self, Self.fullBranding).privacyUrl, "")
        XCTAssertThrowsError(try decode(SchedulingBranding.self, Self.fullBranding.replacingOccurrences(
            of: #""privacy_url":"","#,
            with: ""
        )))
    }

    /// ⚠️ ABSENT LOCALES MEAN "THE KEY DID NOT ARRIVE", WHICH IS NOT THE SAME FACT
    /// AS AN EMPTY LIST. A deployment with no locale table omits it; a tenancy that
    /// genuinely offers none would send `[]`. Both branches decode.
    func testBrandingTellsAnAbsentLocaleTableFromAnEmptyOne() throws {
        let absent = try decode(SchedulingBranding.self, Self.brandingWithoutLocales)
        XCTAssertNil(absent.supportedLocales)
        let empty = try decode(
            SchedulingBranding.self,
            Self.brandingWithoutLocales.replacingOccurrences(
                of: #""fallback_locale":"en""#,
                with: #""fallback_locale":"en","supported_locales":[]"#
            )
        )
        XCTAssertEqual(empty.supportedLocales, [])
    }

    // MARK: - Storage, the notetaker and the summariser

    /// ⛔ BOTH OF THE INTERESTING FIELDS ARE OPTIONAL AND ONE OF THEM IS NOT THE
    /// TENANT'S TO FIX. `recordings_enabled` on with `recordings_storage_ready`
    /// absent is a real state: meetings record and have nowhere to upload to.
    func testStorageSettingsDecodeWithAndWithoutTheInstanceHalf() throws {
        let full = try decode(
            SchedulingStorageSettings.self,
            #"""
            {"recordings_enabled":true,"recordings_storage_ready":false,
             "recordings_prefix":"tenants/contract/recordings"}
            """#
        )
        XCTAssertTrue(full.recordingsEnabled)
        XCTAssertEqual(full.recordingsStorageReady, false)
        XCTAssertEqual(full.recordingsPrefix, "tenants/contract/recordings")

        let bare = try decode(SchedulingStorageSettings.self, #"{"recordings_enabled":false}"#)
        XCTAssertFalse(bare.recordingsEnabled)
        XCTAssertNil(bare.recordingsStorageReady)
        XCTAssertNil(bare.recordingsPrefix)
    }

    /// ⛔ ONE FIELD, AND THE ABSENCES ARE THE CONTRACT. `stt_api_key_set` and
    /// `stt_base_url` are stripped by the catalog because both describe an INSTANCE
    /// credential; this asserts they are ignored rather than modelled, which is the
    /// lenient-in-the-field half of the gate's strict-in-CI rule.
    func testNotetakerSettingsIgnoreTheInstanceFieldsTheCatalogStrips() throws {
        let settings = try decode(
            SchedulingNotetakerSettings.self,
            #"{"enabled":true,"stt_api_key_set":true,"stt_base_url":"https://stt.internal"}"#
        )
        XCTAssertTrue(settings.enabled)
    }

    /// ⛔ THE ALLOWLIST'S SHARPEST CASE. Six more fields exist at the far end and a
    /// tenant may see none of them; a build that grew a property for `model` would
    /// model a key the route strips one hop away.
    func testLLMSettingsCarryOnlyTheTwoFieldsATenantMaySee() throws {
        let settings = try decode(
            SchedulingLLMSettings.self,
            #"""
            {"enabled":true,"extra_instructions":"List the agreed next steps first.",
             "endpoint":"https://llm.internal","model":"gpt-9","api_key_set":true,
             "configured":true,"active":true,"base_prompt":"…"}
            """#
        )
        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.extraInstructions, "List the agreed next steps first.")
    }

    /// ⚠️ `extra_instructions` IS REQUIRED AND `""` IS ITS EMPTY STATE. An Optional
    /// would be a shape the server never sends.
    func testLLMSettingsRequireTheInstructionsKeyEvenWhenEmpty() throws {
        XCTAssertEqual(
            try decode(SchedulingLLMSettings.self, #"{"enabled":false,"extra_instructions":""}"#)
                .extraInstructions,
            ""
        )
        XCTAssertThrowsError(try decode(SchedulingLLMSettings.self, #"{"enabled":false}"#))
    }

    // MARK: - The upload answer

    /// ⛔ ONE KEY, AND **WHICH** KEY DEPENDS ON THE TARGET THAT WAS SENT. The other
    /// two are ABSENT rather than null, which is what lets one type cover all three
    /// uploads and still round-trip each body key-for-key through the strict gate.
    func testEachUploadTargetAnswersItsOwnKeyAndOnlyThat() throws {
        let logo = try decode(SchedulingUploadResult.self, #"{"logo_url":"https://book.test/l.png"}"#)
        XCTAssertEqual(logo.logoUrl, "https://book.test/l.png")
        XCTAssertNil(logo.bannerUrl)
        XCTAssertNil(logo.avatarUrl)
        XCTAssertEqual(logo.publishedUrl, "https://book.test/l.png")

        let banner = try decode(SchedulingUploadResult.self, #"{"banner_url":"https://book.test/b.png"}"#)
        XCTAssertNil(banner.logoUrl)
        XCTAssertEqual(banner.publishedUrl, "https://book.test/b.png")

        let avatar = try decode(SchedulingUploadResult.self, #"{"avatar_url":"https://book.test/a.png"}"#)
        XCTAssertNil(avatar.bannerUrl)
        XCTAssertEqual(avatar.publishedUrl, "https://book.test/a.png")
    }

    /// ⛔ `""` IS REACHABLE AND MEANS "UPLOADED, ADDRESS UNREADABLE". The route
    /// writes `typeof url === "string" ? url : ""`, so a fork that answered 2xx
    /// with a shape it did not recognise yields an empty string rather than an
    /// error — and ``SchedulingUploadResult/publishedUrl`` must hand that back as
    /// `""` rather than skipping to the next key or answering nil.
    func testAnEmptyUrlIsCarriedThroughRatherThanTreatedAsAbsent() throws {
        let result = try decode(SchedulingUploadResult.self, #"{"logo_url":""}"#)
        XCTAssertEqual(result.logoUrl, "")
        XCTAssertEqual(result.publishedUrl, "")
    }

    /// ⚠️ A BODY WITH NO URL KEY AT ALL IS NOT SOMETHING THE ROUTE SENDS, and
    /// ``SchedulingUploadResult/publishedUrl`` answers nil rather than `""` for it
    /// — so "the server said nothing" stays distinguishable from "the server said
    /// the address is unknown".
    func testAnEmptyUploadBodyAnswersNilRatherThanAnEmptyString() throws {
        XCTAssertNil(try decode(SchedulingUploadResult.self, #"{}"#).publishedUrl)
    }

    // MARK: - Bodies

    private static let fullMe = #"""
    {"id":"sched-user-contract","email":"contract@distronode.test","name":"Contract Member",
     "timezone":"America/Toronto","time_format":"24h","week_start":1,"date_format":"ymd",
     "is_admin":true,"is_owner":false,"role":"admin","notify_confirmation":true,
     "notify_cancellation":true,"notify_reschedule":false,"notify_reminder":true,
     "notify_host_booking":true,"notify_host_cancel":false,"notify_host_reschedule":true,
     "avatar_url":"https://book.test/avatars/contract.png"}
    """#

    /// ⚠️ THE SAME SEVENTEEN REQUIRED KEYS AS ``fullMe`` WITH THE AVATAR LEFT OUT,
    /// written out rather than derived by string surgery: a `replacingOccurrences`
    /// that silently matches nothing leaves the test asserting the OTHER polarity
    /// and passing, which is the failure mode this constant removes.
    private static let meWithoutAvatar = #"""
    {"id":"sched-user-contract","email":"contract@distronode.test","name":"Contract Member",
     "timezone":"America/Toronto","time_format":"24h","week_start":1,"date_format":"ymd",
     "is_admin":true,"is_owner":false,"role":"admin","notify_confirmation":true,
     "notify_cancellation":true,"notify_reschedule":false,"notify_reminder":true,
     "notify_host_booking":true,"notify_host_cancel":false,"notify_host_reschedule":true}
    """#

    private static let fullBranding = #"""
    {"business_name":"Contract Agency","logo_url":"https://book.test/branding/logo.png",
     "logo_height":48,"logo_opacity":100,"banner_url":"https://book.test/branding/banner.png",
     "banner_opacity":80,"privacy_url":"","terms_url":"https://www.contract.test/terms",
     "fallback_locale":"en",
     "supported_locales":[{"code":"en","name":"English"},{"code":"fr","name":"Français"}]}
    """#

    private static let brandingWithoutLocales = #"""
    {"business_name":"Contract Agency","logo_url":"","logo_height":0,"logo_opacity":100,
     "banner_url":"","banner_opacity":100,"privacy_url":"","terms_url":"",
     "fallback_locale":"en"}
    """#
}
