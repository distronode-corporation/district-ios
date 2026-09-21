import SwiftUI

/// What the agent may DO on a call, plus the enrichment consent flag. Ported from
/// Android's `CapabilitiesScreen.kt`.
///
/// ⛔ TWO SECTIONS WITH TWO SAVE BUTTONS AND TWO ROUTES, MIRRORING THE WEB
/// DELIBERATELY. The capability allowlist is `PATCH workspace/tools` and the
/// enrichment opt-in is a persona field on `PATCH workspace/persona`, exactly as
/// `EnrichmentSettingsForm` sits inside the web's capabilities tab. One button
/// writing through both would be one tap with two failure modes, and the
/// wholesale-replace one would be the half nobody was thinking about.
///
/// ⛔ NO TOGGLE AND NO SAVE EXISTS WHEN THE CONFIGURATION DID NOT LOAD, and on THIS
/// screen that absence is load-bearing rather than tidy: the allowlist route replaces
/// the stored array with exactly what it receives, so a form rendered from nothing and
/// saved would switch the agent's capabilities off and be answered `{success:true}`.
///
/// ⛔ AND THERE IS A THIRD STATE BETWEEN THOSE TWO: the configuration loaded and
/// carries NO stored allowlist, which is where every workspace starts. The switches are
/// drawn (that is the answer to "what may my agent do") and none of them is editable,
/// because a first save would replace the stored list with exactly the ids THIS BUILD
/// can name. See the ⛔ on ``CapabilitiesModel/storedTools``; without it this screen
/// would delete `send_sms` from every workspace whose operator opened it.
///
/// ⛔ THE OTHER `toolConfig` FIELDS ARE DISPLAYED AND NEVER SENT. The calendar id, the
/// support number and the sender identity are merged per field server-side AND written
/// when present, so `""` would CLEAR them — which is what an empty box on a phone
/// produces.
struct CapabilitiesView: View {
    @State private var model: CapabilitiesModel

    @Environment(\.colorScheme) private var colorScheme

    init(container: AppContainer, workspaceId: String) {
        _model = State(initialValue: CapabilitiesModel(container: container, workspaceId: workspaceId))
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                content
            }
            .padding(DistrictSpacing.gutter)
            .districtReadableWidth()
        }
        .navigationTitle(SettingsCopy.capabilitiesTitle)
        .task {
            await model.loadConfig()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.load {
        case .loading:
            SettingsSkeleton()
        case .ready:
            tools
            enrichment
            connected
        case let .failed(failure):
            SettingsLoadFailureView(failure: failure, onRetry: reload)
        }
    }

    // MARK: - The allowlist

    private var tools: some View {
        SettingsCard(eyebrow: SettingsCopy.capabilitiesEyebrow) {
            Text(SettingsCopy.capabilitiesNote)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
            ForEach(model.rows) { row in
                toolRow(row)
            }
            SettingsSaveNotice(state: model.toolsSave, onReread: reload, onDismiss: model.dismissNotices)
            toolsControl
        }
    }

    /// ⛔ THE SAVE BUTTON IS ABSENT, NOT DISABLED, WHEN THIS WORKSPACE HAS NEVER STORED
    /// AN ALLOWLIST, AND THE SENTENCE THAT REPLACES IT IS THE POINT. A first save from
    /// a phone would store exactly the ids THIS BUILD can name, so a capability added
    /// to District AI after it shipped would be switched off by an operator who never
    /// saw it. A greyed-out button would be a second, weaker way of saying that, and
    /// would leave the operator hunting for what they had failed to fill in. Same call
    /// ``SdrCampaignCard`` makes about its viewer state.
    ///
    /// ⚠️ BRANCHES ON ``CapabilitiesModel/hasStoredTools``, NEVER ON `canEditTools`. The
    /// second is also false while the ENRICHMENT section is saving, through a different
    /// route, and using it here would replace the button with "this workspace has never
    /// chosen which capabilities are on" for the length of that round trip.
    @ViewBuilder
    private var toolsControl: some View {
        if model.hasStoredTools {
            Button(model.toolsSave.isSaving ? "Saving…" : SettingsCopy.capabilitiesSave, action: submitTools)
                .buttonStyle(.districtPrimary)
                .disabled(!model.canSaveTools)
        } else {
            Text(SettingsCopy.capabilitiesNoStoredList)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// ⚠️ AN UNRECOGNISED ID RENDERS BY ID WITH A SENTENCE UNDER IT rather than being
    /// dropped. Dropping it would look tidier and would delete it on the next save,
    /// because the route replaces the array with exactly what arrives.
    ///
    /// ⛔ DISABLED ON ``CapabilitiesModel/canEditTools`` RATHER THAN ON `isSaving`, so
    /// the switches of a workspace with no stored allowlist are drawn as the answer to
    /// "what may my agent do" and not as a control. The model refuses the flip too;
    /// this is the affordance half.
    private func toolRow(_ row: CapabilityRow) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Toggle(row.label ?? row.id, isOn: toolBinding(row))
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
                .disabled(!model.canEditTools)
            if row.label == nil {
                Text(SettingsCopy.capabilitiesUnknownRow)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
            }
        }
    }

    // MARK: - The consent flag

    private var enrichment: some View {
        SettingsCard(eyebrow: SettingsCopy.enrichmentEyebrow) {
            Text(SettingsCopy.enrichmentBody)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.mutedForeground)
            Toggle(SettingsCopy.enrichmentToggle, isOn: enrichmentBinding)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
                .disabled(model.enrichmentSave.isSaving)
            SettingsSaveNotice(state: model.enrichmentSave, onReread: reload, onDismiss: model.dismissNotices)
            Button(model.enrichmentSave.isSaving ? "Saving…" : SettingsCopy.enrichmentSave, action: submitEnrichment)
                .buttonStyle(.districtPrimary)
                .disabled(!model.canSaveEnrichment)
        }
    }

    // MARK: - The accounts the capabilities run through

    /// ⛔ READ-ONLY, AND THE REASON IS THE CLEARING HAZARD RATHER THAN THE ROLE. These
    /// three keys are merged per field by `PATCH workspace/tools` AND written when
    /// present, so an empty box would store `""` and unhook the calendar or the sender
    /// identity. They are shown because they are the observable prerequisites for the
    /// capabilities above: "Transfer to support" without a support number is a switch
    /// that does nothing.
    private var connected: some View {
        SettingsCard(eyebrow: "Connected accounts") {
            SettingsReadOnlyRow(label: "Calendar", value: model.load.config?.toolConfig?.calendarProvider)
            SettingsReadOnlyRow(label: "Calendar id", value: model.load.config?.toolConfig?.calendarId)
            SettingsReadOnlyRow(
                label: "Support number",
                value: model.load.config?.toolConfig?.supportPhoneNumber
            )
            SettingsReadOnlyRow(
                label: "Email sender",
                value: model.load.config?.toolConfig?.customEmailSenderName
            )
        }
    }

    // MARK: - Wiring

    private func toolBinding(_ row: CapabilityRow) -> Binding<Bool> {
        Binding(get: { row.enabled }, set: { model.toggleTool(row.id, to: $0) })
    }

    private var enrichmentBinding: Binding<Bool> {
        Binding(get: { model.enrichmentEnabled }, set: { model.toggleEnrichment(to: $0) })
    }

    private func submitTools() {
        Task { await model.saveTools() }
    }

    private func submitEnrichment() {
        Task { await model.saveEnrichment() }
    }

    private func reload() {
        Task { await model.loadConfig() }
    }
}
