import DistrictData
import DistrictModel
import DistrictNetwork
import Foundation
import XCTest

/// The `me.*` and `settings.*` repository methods.
///
/// ⛔ WHAT IS UNDER TEST IS THE PAIRING, NOT THE JSON. `perform` is generic and
/// decodes whatever the caller names, so the only thing a named method adds is
/// that the op string, the params and the response type agree — and all three are
/// invisible to the compiler, because the op crosses the wire as a string and the
/// type is chosen at the call site. Each test therefore asserts the BODY BYTES as
/// well as the decoded value; a method wired to the wrong op still returns a
/// plausible object.
final class SchedulingAdminSettingsRepositoryTests: XCTestCase {
    private func repository(_ transport: RepositoryTransport) -> SchedulingAdminRepository {
        SchedulingAdminRepository(client: .repositoryTest(transport), reportUnknownOp: { _ in })
    }

    private func envelope(_ data: String) -> String {
        #"{"ok":true,"data":\#(data)}"#
    }

    // MARK: - The caller's own account

    func testMeSendsTheGetOpWithEmptyParams() async throws {
        let transport = RepositoryTransport(json: envelope(Self.meBody))
        let me = try await repository(transport).me(workspaceId: "ws_1")
        XCTAssertEqual(me.id, "sched-user-contract")
        XCTAssertEqual(me.timezone, "America/Toronto")
        XCTAssertEqual(transport.bodies, [#"{"op":"me.get","params":{},"workspaceId":"ws_1"}"#])
    }

    /// ⛔ A SPARSE PATCH SENDS ONLY WHAT WAS SET. ``JSONValue/object(_:)`` drops
    /// nil pairs, and the fork leaves an absent field alone — so the body here is
    /// the difference between changing one preference and resetting eleven.
    func testUpdateMeSendsOnlyTheFieldsThatWereSet() async throws {
        let transport = RepositoryTransport(json: envelope(Self.meBody))
        _ = try await repository(transport).updateMe(
            workspaceId: "ws_1",
            SchedulingMeUpdate(timezone: "Europe/Tallinn", notifyReminder: false)
        )
        XCTAssertEqual(
            transport.bodies,
            [
                #"{"op":"me.patch","params":{"notify_reminder":false,"#
                    + #""timezone":"Europe\/Tallinn"},"workspaceId":"ws_1"}"#,
            ]
        )
    }

    /// ⛔ EVERY KEY IS THE FORK'S SNAKE_CASE AND NOTHING CONVERTS IT. A property
    /// renamed without its string is a field the server never sees and never
    /// complains about, so all twelve are pinned at once.
    func testUpdateMeMapsAllTwelveFieldsToTheForksSpelling() async throws {
        let transport = RepositoryTransport(json: envelope(Self.meBody))
        _ = try await repository(transport).updateMe(
            workspaceId: "ws_1",
            SchedulingMeUpdate(
                name: "Contract Member",
                timezone: "America/Toronto",
                timeFormat: "24h",
                weekStart: 1,
                dateFormat: "ymd",
                notifyConfirmation: true,
                notifyCancellation: true,
                notifyReschedule: false,
                notifyReminder: true,
                notifyHostBooking: true,
                notifyHostCancel: false,
                notifyHostReschedule: true
            )
        )
        XCTAssertEqual(
            transport.bodies,
            [
                #"{"op":"me.patch","params":{"date_format":"ymd","name":"Contract Member","#
                    + #""notify_cancellation":true,"notify_confirmation":true,"notify_host_booking":true,"#
                    + #""notify_host_cancel":false,"notify_host_reschedule":true,"notify_reminder":true,"#
                    + #""notify_reschedule":false,"time_format":"24h","timezone":"America\/Toronto","#
                    + #""week_start":1},"workspaceId":"ws_1"}"#,
            ]
        )
    }

    /// ⚠️ AN UPDATE THAT SETS NOTHING SENDS `{}` RATHER THAN DROPPING THE KEY —
    /// the same rule the descriptor states for an op that takes no params.
    func testAnEmptyUpdateSendsAnEmptyParamsObject() async throws {
        let transport = RepositoryTransport(json: envelope(Self.meBody))
        _ = try await repository(transport).updateMe(workspaceId: "ws_1", SchedulingMeUpdate())
        XCTAssertEqual(transport.bodies, [#"{"op":"me.patch","params":{},"workspaceId":"ws_1"}"#])
    }

    /// ⚠️ THE NO-BODY OPS ANSWER `{"ok":true,"data":{"ok":true}}` — an outer flag
    /// and an inner one — because the catalog's `NO_CONTENT` rewrites a 204 before
    /// it leaves the route.
    func testDeleteAvatarDecodesTheRewrittenNoContent() async throws {
        let transport = RepositoryTransport(json: envelope(#"{"ok":true}"#))
        let answer = try await repository(transport).deleteAvatar(workspaceId: "ws_1")
        XCTAssertTrue(answer.ok)
        XCTAssertEqual(transport.bodies, [#"{"op":"me.avatar.delete","params":{},"workspaceId":"ws_1"}"#])
    }

    // MARK: - Branding

    func testBrandingSendsTheGetOpAndDecodesTheLocaleTable() async throws {
        let transport = RepositoryTransport(json: envelope(Self.brandingBody))
        let branding = try await repository(transport).branding(workspaceId: "ws_1")
        XCTAssertEqual(branding.businessName, "Contract Agency")
        XCTAssertEqual(branding.supportedLocales?.count, 1)
        XCTAssertEqual(transport.bodies, [#"{"op":"settings.branding.get","params":{},"workspaceId":"ws_1"}"#])
    }

    /// ⛔ ALL SEVEN FIELDS TRAVEL, AND THE TWO IMAGE URLs DO NOT. The patch is
    /// REPLACE at the far end — an omitted `privacy_url` CLEARS it — and
    /// `logo_url` is not on the schema at all, so a body carrying one would be a
    /// 400 naming a field that does not exist.
    func testUpdateBrandingRoundTripsEveryFieldAndOmitsTheImageUrls() async throws {
        let transport = RepositoryTransport(json: envelope(Self.brandingBody))
        let read = try await repository(RepositoryTransport(json: envelope(Self.brandingBody)))
            .branding(workspaceId: "ws_1")
        _ = try await repository(transport).updateBranding(
            workspaceId: "ws_1",
            SchedulingBrandingUpdate(from: read)
        )
        XCTAssertEqual(
            transport.bodies,
            [
                #"{"op":"settings.branding.patch","params":{"banner_opacity":80,"#
                    + #""business_name":"Contract Agency","fallback_locale":"en","logo_height":48,"#
                    + #""logo_opacity":100,"privacy_url":"","terms_url":"https:\/\/contract.test\/terms"},"#
                    + #""workspaceId":"ws_1"}"#,
            ]
        )
    }

    /// ⚠️ THE MEMBERWISE INITIALISER IS THE OTHER WAY IN, for a screen building an
    /// update from its own state rather than from a read.
    func testABrandingUpdateBuiltByHandCarriesTheSameKeys() async throws {
        let transport = RepositoryTransport(json: envelope(Self.brandingBody))
        _ = try await repository(transport).updateBranding(
            workspaceId: "ws_2",
            SchedulingBrandingUpdate(
                businessName: "North Studio",
                logoHeight: 32,
                logoOpacity: 90,
                bannerOpacity: 70,
                privacyUrl: "https://north.test/privacy",
                termsUrl: "",
                fallbackLocale: "fr"
            )
        )
        XCTAssertEqual(
            transport.bodies,
            [
                #"{"op":"settings.branding.patch","params":{"banner_opacity":70,"#
                    + #""business_name":"North Studio","fallback_locale":"fr","logo_height":32,"#
                    + #""logo_opacity":90,"privacy_url":"https:\/\/north.test\/privacy","terms_url":""},"#
                    + #""workspaceId":"ws_2"}"#,
            ]
        )
    }

    /// ⛔ THE TWO IMAGE DELETES ARE THE ONLY WAY TO CLEAR EITHER URL, and they are
    /// separate ops rather than one with a target — so a method wired to the wrong
    /// one clears the wrong picture and answers success.
    func testTheTwoBrandingImageDeletesAreDistinctOps() async throws {
        let logo = RepositoryTransport(json: envelope(#"{"ok":true}"#))
        let logoDeleted = try await repository(logo).deleteBrandingLogo(workspaceId: "ws_1")
        XCTAssertTrue(logoDeleted.ok)
        XCTAssertEqual(logo.bodies, [#"{"op":"settings.branding.logo.delete","params":{},"workspaceId":"ws_1"}"#])

        let banner = RepositoryTransport(json: envelope(#"{"ok":true}"#))
        let bannerDeleted = try await repository(banner).deleteBrandingBanner(workspaceId: "ws_1")
        XCTAssertTrue(bannerDeleted.ok)
        XCTAssertEqual(
            banner.bodies,
            [#"{"op":"settings.branding.banner.delete","params":{},"workspaceId":"ws_1"}"#]
        )
    }

    // MARK: - Storage, notetaker, summariser

    func testStorageReadAndWriteUseTheirOwnOps() async throws {
        let read = RepositoryTransport(json: envelope(Self.storageBody))
        let settings = try await repository(read).storageSettings(workspaceId: "ws_1")
        XCTAssertTrue(settings.recordingsEnabled)
        XCTAssertEqual(settings.recordingsStorageReady, true)
        XCTAssertEqual(read.bodies, [#"{"op":"settings.storage.get","params":{},"workspaceId":"ws_1"}"#])

        let write = RepositoryTransport(json: envelope(Self.storageBody))
        _ = try await repository(write).setRecordingsEnabled(workspaceId: "ws_1", false)
        XCTAssertEqual(
            write.bodies,
            [#"{"op":"settings.storage.patch","params":{"recordings_enabled":false},"workspaceId":"ws_1"}"#]
        )
    }

    /// ⛔ THE PATCH SENDS `enabled` AND NOTHING ELSE. The schema is
    /// `z.strictObject`, so a second key is a 400 naming it — `stt_api_key` above
    /// all, which would put a tenant's credential on the shared instance.
    func testNotetakerReadAndWriteUseTheirOwnOps() async throws {
        let read = RepositoryTransport(json: envelope(#"{"enabled":false}"#))
        let current = try await repository(read).notetakerSettings(workspaceId: "ws_1")
        XCTAssertFalse(current.enabled)
        XCTAssertEqual(read.bodies, [#"{"op":"settings.notetaker.get","params":{},"workspaceId":"ws_1"}"#])

        let write = RepositoryTransport(json: envelope(#"{"enabled":true}"#))
        let updated = try await repository(write).setNotetakerEnabled(workspaceId: "ws_1", true)
        XCTAssertTrue(updated.enabled)
        XCTAssertEqual(
            write.bodies,
            [#"{"op":"settings.notetaker.patch","params":{"enabled":true},"workspaceId":"ws_1"}"#]
        )
    }

    func testLLMReadSendsTheGetOp() async throws {
        let transport = RepositoryTransport(json: envelope(#"{"enabled":true,"extra_instructions":"Next steps."}"#))
        let settings = try await repository(transport).llmSettings(workspaceId: "ws_1")
        XCTAssertEqual(settings.extraInstructions, "Next steps.")
        XCTAssertEqual(transport.bodies, [#"{"op":"settings.llm.get","params":{},"workspaceId":"ws_1"}"#])
    }

    /// ⛔ `""` CLEARS THE INSTRUCTIONS AND nil LEAVES THEM ALONE, and the only
    /// difference on the wire is whether the key is there at all.
    func testUpdatingLLMSettingsTellsAnEmptyStringFromAnOmittedField() async throws {
        let cleared = RepositoryTransport(json: envelope(#"{"enabled":true,"extra_instructions":""}"#))
        _ = try await repository(cleared).updateLLMSettings(workspaceId: "ws_1", extraInstructions: "")
        XCTAssertEqual(
            cleared.bodies,
            [#"{"op":"settings.llm.patch","params":{"extra_instructions":""},"workspaceId":"ws_1"}"#]
        )

        let flagOnly = RepositoryTransport(json: envelope(#"{"enabled":false,"extra_instructions":"Keep."}"#))
        _ = try await repository(flagOnly).updateLLMSettings(workspaceId: "ws_1", enabled: false)
        XCTAssertEqual(
            flagOnly.bodies,
            [#"{"op":"settings.llm.patch","params":{"enabled":false},"workspaceId":"ws_1"}"#]
        )
    }

    /// ⚠️ PASSING NEITHER SENDS `{}` — a valid no-op that still spends a write
    /// from the workspace's budget, which is why a caller should decide not to send
    /// it rather than rely on the server ignoring it.
    func testUpdatingLLMSettingsWithNoArgumentsStillSendsAnEmptyObject() async throws {
        let transport = RepositoryTransport(json: envelope(#"{"enabled":true,"extra_instructions":""}"#))
        _ = try await repository(transport).updateLLMSettings(workspaceId: "ws_1")
        XCTAssertEqual(transport.bodies, [#"{"op":"settings.llm.patch","params":{},"workspaceId":"ws_1"}"#])
    }

    /// ⛔ THE OP AND THE RESPONSE TYPE ARE PAIRED HERE AND NOWHERE ELSE, so a
    /// method pointed at a body it cannot decode has to fail as a DECODING error
    /// rather than as a plausible empty object.
    func testAMismatchedBodyIsADecodingFailureRatherThanAnEmptyResult() async {
        let transport = RepositoryTransport(json: envelope(#"{"enabled":true}"#))
        do {
            _ = try await repository(transport).llmSettings(workspaceId: "ws_1")
            XCTFail("expected a decoding failure")
        } catch let error as SchedulingAdminError {
            guard case .decoding = error else {
                return XCTFail("expected .decoding, got \(error)")
            }
            XCTAssertEqual(error.uiCode, .unknown)
        } catch {
            XCTFail("expected a SchedulingAdminError, got \(error)")
        }
    }

    // MARK: - Bodies

    private static let meBody = #"""
    {"id":"sched-user-contract","email":"c@distronode.test","name":"Contract Member",
     "timezone":"America/Toronto","time_format":"24h","week_start":1,"date_format":"ymd",
     "is_admin":true,"is_owner":false,"role":"admin","notify_confirmation":true,
     "notify_cancellation":true,"notify_reschedule":false,"notify_reminder":true,
     "notify_host_booking":true,"notify_host_cancel":false,"notify_host_reschedule":true}
    """#

    private static let brandingBody = #"""
    {"business_name":"Contract Agency","logo_url":"https://book.test/l.png","logo_height":48,
     "logo_opacity":100,"banner_url":"https://book.test/b.png","banner_opacity":80,
     "privacy_url":"","terms_url":"https://contract.test/terms","fallback_locale":"en",
     "supported_locales":[{"code":"en","name":"English"}]}
    """#

    private static let storageBody = #"""
    {"recordings_enabled":true,"recordings_storage_ready":true,
     "recordings_prefix":"tenants/contract/recordings"}
    """#
}
