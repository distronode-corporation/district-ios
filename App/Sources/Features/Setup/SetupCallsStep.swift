import DistrictModel
import SwiftUI

/// Step 5, "Calls, people and bookings". See ``SetupCallsModel``.
struct SetupCallsStep: View {
    @State private var model: SetupCallsModel
    private let baseURL: URL
    private let open: (URL) -> Void

    init(wizard: SetupWizardModel, container: AppContainer, open: @escaping (URL) -> Void) {
        _model = State(initialValue: SetupCallsModel(
            wizard: wizard,
            workspaces: container.workspaces,
            callHandling: container.callHandling
        ))
        baseURL = container.baseURL
        self.open = open
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.section) {
            switch model.phase {
            case .loading:
                SettingsSkeleton()
            case let .failed(failure):
                SettingsLoadFailureView(failure: failure, onRetry: reload)
            case .ready:
                answering
                transfer
                bookings
                if model.profilesOffered {
                    profiles
                }
                if let error = model.error {
                    SetupErrorLine(text: error.message)
                }
                SetupPrimaryButton(
                    title: SetupCopy.continue,
                    busy: model.isContinuing,
                    identifier: A11yID.Setup.Calls.saveAndContinue
                ) {
                    Task { await model.saveAndContinue() }
                }
            }
        }
        .task { await model.load() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.Setup.step("calls"))
    }

    private func reload() {
        Task { await model.load() }
    }

    private var answering: some View {
        SettingsCard(eyebrow: SetupCopy.callsAnswerHeader) {
            SetupNote(text: SetupCopy.callsAnswerDescription, font: DistrictType.caption)
            ForEach(model.modes, id: \.self) { mode in
                SetupChoiceRow(
                    title: Self.title(mode),
                    detail: Self.detail(mode),
                    selected: model.mode == mode,
                    enabled: !model.isSavingAnswering,
                    identifier: A11yID.Setup.choice("mode", mode),
                    action: { model.mode = mode }
                )
            }
            if model.mode == CallHandling.appFirst {
                SetupNote(text: SetupCopy.callsAppNeeded, font: DistrictType.caption)
                Stepper(
                    value: $model.ringSeconds,
                    in: CallHandling.minimumRingSeconds ... CallHandling.maximumRingSeconds
                ) {
                    SettingsReadOnlyRow(
                        label: SetupCopy.callsRingLabel,
                        value: SetupCopy.callsRingSeconds(model.ringSeconds)
                    )
                }
                .disabled(model.isSavingAnswering)
                .accessibilityIdentifier(A11yID.Setup.Calls.ring)
            }
            SetupNote(text: SetupCopy.callsKeepingLineNote, font: DistrictType.caption)
            if model.answeringSaved, !model.answeringChanged {
                SetupNote(text: SetupCopy.saved)
            }
            Button(model.isSavingAnswering ? SetupCopy.saving : SetupCopy.callsSaveAnswering) {
                Task { await model.saveAnswering() }
            }
            .buttonStyle(.districtSecondary)
            .disabled(!model.answeringChanged || model.isSavingAnswering)
            .accessibilityIdentifier(A11yID.Setup.Calls.saveAnswering)
        }
    }

    private var transfer: some View {
        SettingsCard(eyebrow: SetupCopy.callsTransferHeader) {
            SetupNote(text: model.transferNumber.map(SetupCopy.callsTransferCurrent) ?? SetupCopy.callsTransferNone)
            SetupNote(text: SetupCopy.callsTransferWhere, font: DistrictType.caption)
            SetupHandOffButton(
                title: SetupCopy.openSkills,
                page: .skills,
                baseURL: baseURL,
                identifier: A11yID.Setup.Calls.openSkills,
                open: open
            )
        }
    }

    private var bookings: some View {
        SettingsCard(eyebrow: SetupCopy.callsBookingsHeader) {
            SetupNote(text: model.calendarName.map(SetupCopy.callsBookingsConnected) ?? SetupCopy.callsBookingsNone)
            SetupNote(text: SetupCopy.callsBookingsWhere, font: DistrictType.caption)
            SetupHandOffButton(
                title: SetupCopy.openIntegrations,
                page: .integrations,
                baseURL: baseURL,
                identifier: A11yID.Setup.Calls.openIntegrations,
                open: open
            )
        }
    }

    private var profiles: some View {
        SettingsCard(eyebrow: SetupCopy.callsProfilesHeader) {
            Toggle(SetupCopy.callsProfilesToggle, isOn: Binding(
                get: { model.profilesOn },
                set: { on in Task { await model.setProfiles(on) } }
            ))
            .font(DistrictType.bodySmall)
            .disabled(model.isSavingProfiles)
            .accessibilityIdentifier(A11yID.Setup.Calls.profiles)
            SetupNote(text: SetupCopy.callsProfilesBody, font: DistrictType.caption)
            SetupNote(text: model.profilesOn ? SetupCopy.callsProfilesOn : SetupCopy.callsProfilesOff)
        }
    }

    static func title(_ mode: String) -> String {
        switch mode {
        case CallHandling.appFirst: SetupCopy.callsAppFirst
        case CallHandling.aiThenApp: SetupCopy.callsAiThenApp
        default: SetupCopy.callsAiFirst
        }
    }

    static func detail(_ mode: String) -> String {
        switch mode {
        case CallHandling.appFirst: SetupCopy.callsAppFirstDescription
        case CallHandling.aiThenApp: SetupCopy.callsAiThenAppDescription
        default: SetupCopy.callsAiFirstDescription
        }
    }
}
