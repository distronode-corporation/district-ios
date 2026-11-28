@testable import DistrictAI
import DistrictData
import DistrictModel
import SwiftUI
import XCTest

/// The settings screen's four editors, opened over the recorded profile, branding and
/// assistant: as opened, refused before sending, refused by the scheduler, and saved.
final class SchedulingSettingsWriteSnapshotTests: SchedulingWriteSnapshotCase {
    // MARK: - Profile

    func testProfileRecorded() async throws {
        let me = try await recordedMe()
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingProfileSheet(model: self.profile(container, me), onClose: {})
        }
    }

    /// An emptied name, refused on Save before anything is sent.
    func testProfileNameMissing() async throws {
        let me = try await recordedMe()
        try await assertScreen(devices: [.iPhone]) { container in
            let model = self.profile(container, me)
            model.editName("   ")
            return SnapshotPrepared(SchedulingProfileSheet(model: model, onClose: {})) { await model.save() }
        }
    }

    func testProfileSaved() async throws {
        let me = try await recordedMe()
        try await assertScreen(["op:me.patch": .fixture("district-scheduling-me")], devices: [.iPhone]) { container in
            let model = self.profile(container, me)
            return SnapshotPrepared(SchedulingProfileSheet(model: model, onClose: {})) { await model.save() }
        }
    }

    func testProfileSaveRefused() async throws {
        let me = try await recordedMe()
        try await assertScreen(["op:me.patch": .refused], devices: [.iPhone], locales: [.en]) { container in
            let model = self.profile(container, me)
            return SnapshotPrepared(SchedulingProfileSheet(model: model, onClose: {})) { await model.save() }
        }
    }

    /// ⚠️ A FILE OF A TYPE THE SCHEDULER REFUSES is refused on the picture's own row, and no
    /// upload is sent.
    func testProfileAvatarWrongType() async throws {
        let me = try await recordedMe()
        try await assertScreen(devices: [.iPhone]) { container in
            let model = self.profile(container, me)
            return SnapshotPrepared(SchedulingProfileSheet(model: model, onClose: {})) {
                await model.uploadAvatar(bytes: Data("%PDF-1.7".utf8), mimeType: "application/pdf")
            }
        }
    }

    /// The picker handed back nothing readable: a third answer, not a refused type.
    func testProfileAvatarUnreadable() async throws {
        let me = try await recordedMe()
        try await assertScreen(devices: [.iPhone], locales: [.en]) { container in
            let model = self.profile(container, me)
            model.reportUnreadableAvatar()
            return SchedulingProfileSheet(model: model, onClose: {})
        }
    }

    /// Removed: the re-read profile carries no picture, so the remove control goes.
    func testProfileAvatarRemoved() async throws {
        let me = try await recordedMe()
        let noAvatar = FixtureTransport.Reply.json("""
        {"ok":true,"data":{"id":"sched-user-contract","email":"contract@distronode.test",
         "name":"Contract Member","timezone":"America/Toronto","time_format":"24h","week_start":1,
         "date_format":"ymd","is_admin":true,"is_owner":false,"role":"admin",
         "notify_confirmation":true,"notify_cancellation":true,"notify_reschedule":false,
         "notify_reminder":true,"notify_host_booking":true,"notify_host_cancel":false,
         "notify_host_reschedule":true,"avatar_url":null}}
        """)
        try await assertScreen(
            ["op:me.avatar.delete": .fixture("district-scheduling-ok"), "op:me.get": noAvatar],
            devices: [.iPhone]
        ) { container in
            let model = self.profile(container, me)
            return SnapshotPrepared(SchedulingProfileSheet(model: model, onClose: {})) { await model.deleteAvatar() }
        }
    }

    // MARK: - Notifications

    func testNotificationsRecorded() async throws {
        let me = try await recordedMe()
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingNotificationsSheet(model: self.notifications(container, me), onClose: {})
        }
    }

    func testNotificationsSaveRefused() async throws {
        let me = try await recordedMe()
        try await assertScreen(["op:me.patch": .notReady], devices: [.iPhone], locales: [.en]) { container in
            let model = self.notifications(container, me)
            model.editReschedule(true)
            return SnapshotPrepared(SchedulingNotificationsSheet(model: model, onClose: {})) { await model.save() }
        }
    }

    // MARK: - Branding

    func testBrandingRecorded() async throws {
        let branding = try await admin().branding(workspaceId: Self.workspace)
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingBrandingSheet(model: self.branding(container, branding), onClose: {})
        }
    }

    /// A business name over the limit, refused on Save.
    func testBrandingNameTooLong() async throws {
        let branding = try await admin().branding(workspaceId: Self.workspace)
        try await assertScreen(devices: [.iPhone], locales: [.en]) { container in
            let model = self.branding(container, branding)
            model.editBusinessName(String(repeating: "A", count: SchedulingSettingsWriteCopy.businessNameLimit + 1))
            return SnapshotPrepared(SchedulingBrandingSheet(model: model, onClose: {})) { await model.save() }
        }
    }

    func testBrandingSaveRefused() async throws {
        let branding = try await admin().branding(workspaceId: Self.workspace)
        try await assertScreen(["op:settings.branding.patch": .refused], devices: [.iPhone]) { container in
            let model = self.branding(container, branding)
            model.editBusinessName("Contract Agency Inc.")
            return SnapshotPrepared(SchedulingBrandingSheet(model: model, onClose: {})) { await model.save() }
        }
    }

    /// A banner of a type the scheduler refuses: refused on the banner's own row.
    func testBrandingBannerWrongType() async throws {
        let branding = try await admin().branding(workspaceId: Self.workspace)
        try await assertScreen(devices: [.iPhone], locales: [.en]) { container in
            let model = self.branding(container, branding)
            return SnapshotPrepared(SchedulingBrandingSheet(model: model, onClose: {})) {
                await model.upload(bytes: Data("GIF89a".utf8), mimeType: "image/tiff", target: .banner)
            }
        }
    }

    /// No logo or banner published and no languages to fall back to.
    func testBrandingBare() async throws {
        let bare = FixtureTransport.Reply.json("""
        {"ok":true,"data":{"business_name":"","logo_url":"","logo_height":48,"logo_opacity":100,
         "banner_url":"","banner_opacity":100,"privacy_url":"","terms_url":"","fallback_locale":"en",
         "supported_locales":[]}}
        """)
        let branding = try await admin(["op:settings.branding.get": bare]).branding(workspaceId: Self.workspace)
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingBrandingSheet(model: self.branding(container, branding), onClose: {})
        }
    }

    // MARK: - The booking assistant

    func testAutomationRecorded() async throws {
        let llm = try await admin().llmSettings(workspaceId: Self.workspace)
        try await assertScreen(devices: [.iPhone]) { container in
            SchedulingAutomationSheet(model: self.automation(container, llm), onClose: {})
        }
    }

    /// Instructions over the 4000-character cap, refused before the scheduler's
    /// field-name-only refusal can arrive.
    func testAutomationInstructionsTooLong() async throws {
        let llm = try await admin().llmSettings(workspaceId: Self.workspace)
        try await assertScreen(devices: [.iPhone], locales: [.en]) { container in
            let model = self.automation(container, llm)
            model.editInstructions(String(
                repeating: "x",
                count: SchedulingSettingsWriteCopy.assistantInstructionsLimit + 1
            ))
            return SnapshotPrepared(SchedulingAutomationSheet(model: model, onClose: {})) { await model.save() }
        }
    }

    func testAutomationSaved() async throws {
        let llm = try await admin().llmSettings(workspaceId: Self.workspace)
        let saved = FixtureTransport.Reply.json(#"{"ok":true,"data":{"enabled":false,"extra_instructions":""}}"#)
        try await assertScreen(["op:settings.llm.patch": saved], devices: [.iPhone]) { container in
            let model = self.automation(container, llm)
            model.editAssistant(false)
            model.editInstructions("")
            return SnapshotPrepared(SchedulingAutomationSheet(model: model, onClose: {})) { await model.save() }
        }
    }

    // MARK: - Models

    private func profile(_ container: AppContainer, _ me: SchedulingMe) -> SchedulingProfileModel {
        SchedulingProfileModel(
            admin: container.schedulingAdmin,
            media: container.schedulingAdminMedia,
            workspaceId: Self.workspace,
            me: me,
            onSaved: { _ in }
        )
    }

    private func notifications(_ container: AppContainer, _ me: SchedulingMe) -> SchedulingNotificationsModel {
        SchedulingNotificationsModel(
            admin: container.schedulingAdmin,
            workspaceId: Self.workspace,
            me: me,
            onSaved: { _ in }
        )
    }

    private func branding(_ container: AppContainer, _ branding: SchedulingBranding) -> SchedulingBrandingModel {
        SchedulingBrandingModel(
            admin: container.schedulingAdmin,
            media: container.schedulingAdminMedia,
            workspaceId: Self.workspace,
            branding: branding,
            onSaved: { _ in }
        )
    }

    private func automation(_ container: AppContainer, _ llm: SchedulingLLMSettings) -> SchedulingAutomationModel {
        SchedulingAutomationModel(admin: container.schedulingAdmin, workspaceId: Self.workspace, llm: llm, onSaved: {})
    }
}
