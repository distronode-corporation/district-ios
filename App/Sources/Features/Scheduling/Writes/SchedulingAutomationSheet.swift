import SwiftUI

/// The booking assistant: its switch and its extra instructions.
struct SchedulingAutomationSheet: View {
    @Bindable var model: SchedulingAutomationModel
    let onClose: () -> Void

    var body: some View {
        SchedulingWriteSheet(
            title: SchedulingSettingsWriteCopy.automationTitle,
            subtitle: nil,
            cancelLabel: SchedulingTeamWriteCopy.close,
            confirmLabel: SchedulingSettingsWriteCopy.automationSave,
            confirmEnabled: model.isDirty,
            confirmIdentifier: A11yID.SchedulingWritesB.automationSave,
            state: model.state
        ) {
            VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                assistant
                SchedulingWriteRejection(message: model.rejected)
            }
        } onCancel: {
            onClose()
        } onConfirm: {
            Task { await model.save() }
        }
        .accessibilityIdentifier(A11yID.SchedulingWritesB.automationSheet)
    }

    /// ⛔ NO API-KEY FIELD, AND THERE MUST NEVER BE ONE. The catalog's schema is
    /// `z.strictObject`, so anything beyond `enabled` and `extra_instructions` is a
    /// 400 naming the field — deliberately, because silently accepting a credential
    /// a customer believes they set is the worse of the two failures.
    private var assistant: some View {
        SettingsCard(eyebrow: SchedulingSettingsWriteCopy.assistantLabel) {
            VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                Toggle(
                    SchedulingSettingsWriteCopy.assistantToggle,
                    isOn: Binding(get: { model.assistantEnabled }, set: { model.editAssistant($0) })
                )
                .disabled(model.busy)
                .accessibilityIdentifier(A11yID.SchedulingWritesB.automationAssistant)
                SchedulingWriteHint(text: SchedulingSettingsWriteCopy.assistantHint)
                SettingsField(
                    label: SchedulingSettingsWriteCopy.assistantInstructionsLabel,
                    text: Binding(get: { model.instructions }, set: { model.editInstructions($0) }),
                    enabled: !model.busy,
                    multiline: true
                )
                .accessibilityIdentifier(A11yID.SchedulingWritesB.automationInstructions)
                SchedulingWriteHint(text: SchedulingSettingsWriteCopy.assistantInstructionsHint)
            }
        }
    }
}
