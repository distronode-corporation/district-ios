import DistrictData
import DistrictModel
import Observation
import SwiftUI

/// The booking page, the recordings, the profile and the notifications.
///
/// ⛔ FOUR TABS, AND ONLY THE ACTIVE ONE READS. The web mounts one tab's content at a time
/// for the same reason: four reads on entry would spend three requests for panels nobody
/// opened. ⚠️ A tab that has already loaded is NOT re-read when it is returned to, which is
/// what makes switching back and forth free.
@MainActor
@Observable
final class SchedulingSettingsModel {
    private(set) var tab = SchedulingSettingsFormat.settingsTabIds[0]

    private(set) var branding: SchedulingSectionState<SchedulingBranding>?
    private(set) var recordings: SchedulingSectionState<RecordingSettings>?
    private(set) var profile: SchedulingSectionState<SchedulingMe>?

    /// ⚠️ THREE READS BEHIND ONE TAB, so the tab has one state rather than three. They are
    /// all storage-shaped and a partial answer here would be a panel that could not say
    /// whether recording is on.
    struct RecordingSettings {
        let storage: SchedulingStorageSettings
        let notetaker: SchedulingNotetakerSettings
        let llm: SchedulingLLMSettings
    }

    private let repository: SchedulingAdminRepository
    private let workspaceId: String

    /// ⛔ THE DESIGNATED INITIALISER TAKES THE REPOSITORIES AND THE CONTAINER ONE
    /// DELEGATES TO IT, WHICH IS THE ONLY TEST SEAM ON THIS SURFACE. ``AppContainer``
    /// builds its own ``URLSessionHTTPTransport`` in `init`, so a test cannot hand it a
    /// fake; taking the collaborators directly lets `DistrictAITests` drive a real
    /// repository over a stub transport, which exercises the envelope walk rather than
    /// skipping it. ⚠️ Production still constructs through the container, so both
    /// collaborators remain the one shared ``ApiClient``.
    init(repository: SchedulingAdminRepository, workspaceId: String) {
        self.repository = repository
        self.workspaceId = workspaceId
    }

    convenience init(container: AppContainer, workspaceId: String) {
        self.init(repository: container.schedulingAdmin, workspaceId: workspaceId)
    }

    func selectTab(_ next: String) async {
        tab = next
        await loadCurrentTab()
    }

    /// ⚠️ IDEMPOTENT: a tab that already has a state is left alone. Pull-to-refresh calls
    /// ``reload()``, which clears first.
    func loadCurrentTab() async {
        switch tab {
        case "booking-page" where branding == nil:
            await loadBranding()
        case "recordings" where recordings == nil:
            await loadRecordings()
        // ⛔ THE PROFILE TAB AND THE NOTIFICATIONS TAB SHARE ONE READ, because they are two
        // views of one `me.get` payload. Reading it twice would spend a request to display
        // fields the client is already holding.
        case "profile", "notifications" where profile == nil:
            if profile == nil {
                await loadProfile()
            }
        default:
            break
        }
    }

    func reload() async {
        switch tab {
        case "booking-page": branding = nil
        case "recordings": recordings = nil
        default: profile = nil
        }
        await loadCurrentTab()
    }

    private func loadBranding() async {
        branding = .loading
        do {
            branding = try await .ready(repository.branding(workspaceId: workspaceId))
        } catch {
            branding = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    private func loadRecordings() async {
        recordings = .loading
        do {
            async let storage = repository.storageSettings(workspaceId: workspaceId)
            async let notetaker = repository.notetakerSettings(workspaceId: workspaceId)
            async let llm = repository.llmSettings(workspaceId: workspaceId)
            recordings = try await .ready(RecordingSettings(
                storage: storage,
                notetaker: notetaker,
                llm: llm
            ))
        } catch {
            recordings = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    private func loadProfile() async {
        profile = .loading
        do {
            profile = try await .ready(repository.me(workspaceId: workspaceId))
        } catch {
            profile = .failed(SchedulingFailureCopy.text(forAny: error))
        }
    }

    // MARK: - Writes

    // ⛔ THE BRANDING PATCH IS A **WHOLESALE REPLACE** AND IS THE MOST DANGEROUS FORM ON
    // THIS SURFACE. `settings.branding.patch` sends all seven fields every time, so a form
    // rendered from a FAILED read and then saved does not save nothing — it blanks the
    // business name, the privacy link and the terms link on a customer-facing page. The
    // workspace-settings surface has the same trap; `SettingsLoadFailureView` exists for
    // it. ``branding`` is a `SchedulingSectionState` so the guard is
    // structural.
    //
    // ⛔ AND THE ROLE RULES DIFFER WITHIN THIS ONE SCREEN, WHICH IS THE TRAP. Branding,
    // storage, notetaker and LLM are `client`-level; `me.patch` and `me.avatar.delete`
    // are `viewer`-level, because they touch only the caller's OWN profile — a viewer who
    // cannot set their own timezone is offered every booking window in the wrong hours.
    // So the Profile and Notifications tabs must stay editable for a viewer while the
    // other two are not. Gating this whole screen on
    // ``WorkspaceRole/allowsMutation(_:)`` would be wrong.
    //
    // ⚠️ The validators (`brandingPatchFrom`, `profilePatchFrom`, `legalUrlProblem`) were
    // deliberately left in the web; see the ⛔ on ``SchedulingSettingsFormat``.
}

struct SchedulingSettingsView: View {
    @State private var model: SchedulingSettingsModel

    /// ⚠️ THE MEDIA REPOSITORY IS HELD TOO, because the avatar, the logo and the
    /// banner are multipart uploads on their own route rather than catalog ops.
    private let admin: SchedulingAdminRepository
    private let media: SchedulingAdminMediaRepository
    private let workspaceId: String
    private let role: WorkspaceRole?

    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String, role: WorkspaceRole?) {
        self.workspaceId = workspaceId
        self.role = role
        admin = container.schedulingAdmin
        media = container.schedulingAdminMedia
        _model = State(initialValue: SchedulingSettingsModel(
            container: container,
            workspaceId: workspaceId
        ))
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    /// ⛔ THIS GATES TWO OF THE FOUR TABS AND MUST NEVER GATE THE OTHER TWO.
    /// Branding, storage, notetaker and LLM are `client`-level; `me.patch` and
    /// `me.avatar.delete` are `viewer`-level, because they touch only the caller's
    /// OWN profile — a viewer who cannot set their own timezone is offered every
    /// booking window in the wrong hours.
    private var canManage: Bool {
        WorkspaceRole.allowsMutation(role)
    }

    var body: some View {
        SchedulingSectionScroll(
            title: SchedulingCopy.sectionTitle(.settings),
            identifier: A11yID.Scheduling.settingsRoot,
            onRefresh: { await model.reload() },
            content: {
                tabs
                content
            }
        )
        .task { await model.loadCurrentTab() }
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DistrictSpacing.tight) {
                ForEach(
                    Array(SchedulingSettingsFormat.settingsTabIds.enumerated()),
                    id: \.offset
                ) { index, id in
                    Button(SchedulingSettingsFormat.settingsTabLabels[index]) {
                        Task { await model.selectTab(id) }
                    }
                    .buttonStyle(DistrictButtonStyle(
                        variant: model.tab == id ? .primary : .secondary
                    ))
                    .accessibilityIdentifier(A11yID.Scheduling.settingsTab(id))
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.tab {
        case "booking-page": brandingTab
        case "recordings": recordingsTab
        case "profile": profileTab
        default: notificationsTab
        }
    }

    private var brandingTab: some View {
        SchedulingCard(eyebrow: SchedulingSettingsFormat.settingsTabLabels[0]) {
            switch model.branding {
            case .loading, .none:
                SettingsSkeleton()
            case let .failed(failure):
                FailureView(failure: failure, onRetry: reload)
            case let .ready(branding):
                SchedulingReadOnlyRow(
                    label: SchedulingCopy.brandingBusinessName,
                    value: branding.businessName.isEmpty ? nil : branding.businessName
                )
                SchedulingReadOnlyRow(
                    label: SchedulingCopy.brandingLogo,
                    value: branding.logoUrl.isEmpty ? SchedulingCopy.notSet : SchedulingCopy.set
                )
                SchedulingReadOnlyRow(
                    label: SchedulingCopy.brandingBanner,
                    value: branding.bannerUrl.isEmpty ? SchedulingCopy.notSet : SchedulingCopy.set
                )
                SchedulingReadOnlyRow(
                    label: SchedulingCopy.brandingPrivacy,
                    value: branding.privacyUrl.isEmpty ? nil : branding.privacyUrl
                )
                SchedulingReadOnlyRow(
                    label: SchedulingCopy.brandingTerms,
                    value: branding.termsUrl.isEmpty ? nil : branding.termsUrl
                )
                SchedulingReadOnlyRow(
                    label: SchedulingCopy.brandingLocale,
                    value: SchedulingSettingsFormat.localeLabel(
                        code: branding.fallbackLocale,
                        supported: branding.supportedLocales
                    )
                )
                if canManage {
                    SchedulingBrandingEditButton(
                        admin: admin,
                        media: media,
                        workspaceId: workspaceId,
                        branding: branding,
                        onSaved: reload
                    )
                }
            }
        }
    }

    private var recordingsTab: some View {
        SchedulingCard(eyebrow: SchedulingSettingsFormat.settingsTabLabels[1]) {
            switch model.recordings {
            case .loading, .none:
                SettingsSkeleton()
            case let .failed(failure):
                FailureView(failure: failure, onRetry: reload)
            case let .ready(settings):
                // ⛔ THE DESCRIPTION TRACKS STORAGE READINESS AND NOT THE TOGGLE: a region
                // with no storage cannot record whatever the switch says.
                Text(SchedulingSettingsFormat.recordingDescription(settings.storage))
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.mutedForeground)
                SchedulingReadOnlyRow(
                    label: SchedulingCopy.recordingsEnabled,
                    value: SchedulingCopy.onOff(settings.storage.recordingsEnabled)
                )
                SchedulingReadOnlyRow(
                    label: SchedulingCopy.notetakerEnabled,
                    value: SchedulingCopy.onOff(settings.notetaker.enabled)
                )
                SchedulingReadOnlyRow(
                    label: SchedulingCopy.assistantEnabled,
                    value: SchedulingCopy.onOff(settings.llm.enabled)
                )
                if !settings.llm.extraInstructions.isEmpty {
                    SchedulingReadOnlyRow(
                        label: SchedulingCopy.assistantInstructions,
                        value: settings.llm.extraInstructions
                    )
                }
                if canManage {
                    SchedulingAutomationEditButton(
                        admin: admin,
                        workspaceId: workspaceId,
                        storage: settings.storage,
                        notetaker: settings.notetaker,
                        llm: settings.llm,
                        onSaved: reload
                    )
                }
            }
        }
    }

    private var profileTab: some View {
        SchedulingCard(eyebrow: SchedulingSettingsFormat.settingsTabLabels[2]) {
            switch model.profile {
            case .loading, .none:
                SettingsSkeleton()
            case let .failed(failure):
                FailureView(failure: failure, onRetry: reload)
            case let .ready(me):
                SchedulingReadOnlyRow(label: SchedulingCopy.profileName, value: me.name)
                SchedulingReadOnlyRow(label: SchedulingCopy.profileTimezone, value: me.timezone)
                SchedulingReadOnlyRow(
                    label: SchedulingCopy.profileTimeFormat,
                    value: SchedulingSettingsFormat.timeFormatLabel(me.timeFormat)
                )
                SchedulingReadOnlyRow(
                    label: SchedulingCopy.profileWeekStart,
                    value: SchedulingSettingsFormat.weekStartLabel(me.weekStart)
                )
                SchedulingReadOnlyRow(
                    label: SchedulingCopy.profileDateFormat,
                    value: SchedulingSettingsFormat.dateFormatLabel(me.dateFormat)
                )
                // ⛔ UNGATED ON PURPOSE. `me.patch` and `me.avatar.delete` are
                // `viewer`-level; see the ⛔ on ``canManage``.
                SchedulingProfileEditButton(
                    admin: admin,
                    media: media,
                    workspaceId: workspaceId,
                    me: me,
                    onSaved: reload
                )
            }
        }
    }

    @ViewBuilder
    private var notificationsTab: some View {
        switch model.profile {
        case .loading, .none:
            SettingsSkeleton()
        case let .failed(failure):
            FailureView(failure: failure, onRetry: reload)
        case let .ready(me):
            ForEach(SchedulingSettingsFormat.notificationGroups, id: \.heading) { group in
                SchedulingCard(eyebrow: group.heading) {
                    Text(group.description)
                        .font(DistrictType.caption)
                        .foregroundStyle(colors.mutedForeground)
                    ForEach(group.switches, id: \.field) { entry in
                        SchedulingReadOnlyRow(
                            label: entry.label,
                            // ⚠️ nil RATHER THAN "Off" FOR A FIELD THE TABLE NAMES AND THE
                            // PAYLOAD DOES NOT CARRY. `SettingsReadOnlyRow` renders "Not
                            // set" for nil, which is the truth; drawing "Off" would assert
                            // a choice nobody made.
                            value: SchedulingSettingsFormat
                                .notificationValue(entry.field, on: me)
                                .map(SchedulingCopy.onOff)
                        )
                    }
                }
            }
            // ⛔ UNGATED, FOR THE SAME REASON THE PROFILE TAB IS: these seven switches
            // are the caller's own `me.patch`.
            SchedulingNotificationsEditButton(
                admin: admin,
                workspaceId: workspaceId,
                me: me,
                onSaved: reload
            )
        }
    }

    private func reload() {
        Task { await model.reload() }
    }
}
