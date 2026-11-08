import DistrictModel
import SwiftUI

/// Step 3, "Your receptionist". See ``SetupReceptionistModel``.
struct SetupReceptionistStep: View {
    @State private var model: SetupReceptionistModel

    init(wizard: SetupWizardModel, container: AppContainer) {
        _model = State(initialValue: SetupReceptionistModel(wizard: wizard, workspaces: container.workspaces))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.section) {
            switch model.phase {
            case .loading:
                SettingsSkeleton()
            case let .failed(failure):
                SettingsLoadFailureView(failure: failure, onRetry: { Task { await model.load() } })
            case .ready:
                form
            }
        }
        .task { await model.load() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.Setup.step("receptionist"))
    }

    private var form: some View {
        SettingsCard {
            SetupField(
                label: SetupCopy.receptionistNameLabel,
                text: $model.name,
                error: model.showErrors ? model.nameError : nil,
                identifier: A11yID.Setup.Receptionist.name
            )
            .onChange(of: model.name) { model.nameChanged() }
            SetupField(
                label: SetupCopy.receptionistGreetingLabel,
                text: $model.greeting,
                hint: SetupCopy.receptionistGreetingHint,
                error: model.showErrors ? model.greetingError : nil,
                multiline: true,
                identifier: A11yID.Setup.Receptionist.greeting
            )
            voice
            if model.disclosureIsMandatory {
                SetupNote(text: SetupCopy.receptionistDisclosureAlways + " " + SetupCopy.receptionistDisclosureRequired)
            }
            if let error = model.saveError {
                SetupErrorLine(text: error.message)
            }
            SetupPrimaryButton(
                title: SetupCopy.saveAndContinue,
                busy: model.isSaving,
                identifier: A11yID.Setup.Receptionist.save
            ) {
                Task { await model.save() }
            }
        }
    }

    @ViewBuilder
    private var voice: some View {
        if model.voiceGroups.isEmpty {
            SetupNote(text: SetupCopy.receptionistVoiceElsewhere)
        } else {
            SetupPicker(
                label: SetupCopy.receptionistVoiceLabel,
                placeholder: SetupCopy.receptionistVoiceLabel,
                selection: model.voice ?? "",
                options: model.voiceGroups.flatMap(\.options).map { ($0.value, $0.label) },
                identifier: A11yID.Setup.Receptionist.voice,
                choose: { model.voice = $0 }
            )
        }
    }
}
