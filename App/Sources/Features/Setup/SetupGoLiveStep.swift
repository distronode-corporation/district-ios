import DistrictModel
import SwiftUI

/// Step 6, "Test and go live". See ``SetupGoLiveModel``.
struct SetupGoLiveStep: View {
    @State private var model: SetupGoLiveModel
    private let wizard: SetupWizardModel

    init(wizard: SetupWizardModel, container: AppContainer) {
        _model = State(initialValue: SetupGoLiveModel(
            wizard: wizard,
            workspaces: container.workspaces,
            callHandling: container.callHandling
        ))
        self.wizard = wizard
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.section) {
            testCall
            if model.forwarding?.available == true {
                forwarding
            }
            live
        }
        .task { await model.load() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(A11yID.Setup.step("golive"))
    }

    // MARK: - The test call

    private var testCall: some View {
        SettingsCard(eyebrow: SetupCopy.goliveTestHeader) {
            SetupNote(text: SetupCopy.goliveTestDescription, font: DistrictType.caption)
            if model.hasNumber {
                SetupField(
                    label: SetupCopy.goliveMobileLabel,
                    text: $model.mobile,
                    error: model.mobileError ? SetupCopy.goliveMobileError : nil,
                    placeholder: "+14165550123",
                    keyboard: .phonePad,
                    content: .telephoneNumber,
                    identifier: A11yID.Setup.GoLive.mobile
                )
                VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                    DistrictEyebrow(text: SetupCopy.goliveConsentHeading)
                    SetupNote(text: SetupCopy.goliveConsentWording, font: DistrictType.caption)
                }
                .accessibilityElement(children: .combine)
                SetupPrimaryButton(
                    title: SetupCopy.goliveCallMe,
                    busy: model.isCalling,
                    enabled: !model.mobile.trimmed.isEmpty,
                    identifier: A11yID.Setup.GoLive.callMe
                ) {
                    Task { await model.callMe() }
                }
                callStatus
            } else {
                SetupNote(text: SetupCopy.goliveNoNumberYet)
            }
        }
    }

    @ViewBuilder
    private var callStatus: some View {
        switch model.callStatus {
        case .calling:
            SetupNote(text: SetupCopy.goliveCalling).accessibilityIdentifier(A11yID.Setup.GoLive.callStatus)
        case let .failed(text):
            SetupErrorLine(text: text).accessibilityIdentifier(A11yID.Setup.GoLive.callStatus)
        case nil:
            EmptyView()
        }
    }

    // MARK: - The forwarding check

    private var forwarding: some View {
        SettingsCard(eyebrow: SetupCopy.goliveKeepingHeader) {
            SetupNote(text: SetupCopy.goliveKeepingDescription, font: DistrictType.caption)
            DistrictEyebrow(text: SetupCopy.goliveCheckHeader)
                .accessibilityAddTraits(.isHeader)
            SetupNote(text: SetupCopy.goliveCheckDescription, font: DistrictType.caption)
            SetupField(
                label: SetupCopy.goliveBusinessLineLabel,
                text: $model.businessLine,
                error: model.lineError ? SetupCopy.goliveBusinessLineError : nil,
                placeholder: "+14165550123",
                keyboard: .phonePad,
                content: .telephoneNumber,
                identifier: A11yID.Setup.GoLive.businessLine
            )
            DistrictEyebrow(text: SetupCopy.goliveModeLabel)
            ForEach(ForwardingCheckMode.allCases, id: \.self) { mode in
                SetupChoiceRow(
                    title: mode == .all ? SetupCopy.goliveModeAll : SetupCopy.goliveModeUnanswered,
                    selected: model.mode == mode,
                    enabled: !model.checkIsPending,
                    identifier: A11yID.Setup.choice("forwarding", mode.rawValue),
                    action: { model.mode = mode }
                )
            }
            if model.mode == .unanswered {
                SetupNote(text: SetupCopy.goliveUnansweredNote, font: DistrictType.caption)
            }
            if let verifier = model.forwarding?.forwardingCheck?.verifierNumber, model.checkIsPending {
                SetupNote(text: SetupCopy.goliveExpectCall(verifier))
            }
            SetupPrimaryButton(
                title: SetupCopy.goliveStartCheck,
                busy: model.isStartingCheck || model.checkIsPending,
                enabled: !model.businessLine.trimmed.isEmpty && model.forwarding?.attemptsLeft != 0,
                identifier: A11yID.Setup.GoLive.startCheck
            ) {
                Task { await model.startCheck() }
            }
            checkStatus
        }
    }

    private var checkStatus: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            if let error = model.checkError {
                SetupErrorLine(text: error)
            } else if let sentence = model.checkSentence {
                SetupNote(text: sentence)
            }
            if let attempts = model.attemptsSentence {
                SetupNote(text: attempts, font: DistrictType.caption)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(A11yID.Setup.GoLive.checkStatus)
    }

    // MARK: - Live

    private var live: some View {
        SettingsCard(eyebrow: SetupCopy.goliveLiveHeader) {
            if let summary = model.summary {
                VStack(alignment: .leading, spacing: DistrictSpacing.tight) {
                    SettingsReadOnlyRow(
                        label: SetupCopy.goliveGreetingLabel,
                        value: summary.greeting.isEmpty ? SetupCopy.goliveNoGreeting : summary.greeting
                    )
                    SettingsReadOnlyRow(label: SetupCopy.goliveAnswersLabel, value: Self.answers(summary))
                }
                .accessibilityIdentifier(A11yID.Setup.GoLive.summary)
            }
            SetupPrimaryButton(
                title: SetupCopy.goliveFinish,
                busy: wizard.isCompleting,
                identifier: A11yID.Setup.GoLive.finish
            ) {
                Task { await model.finish() }
            }
        }
    }

    static func answers(_ summary: SetupGoLiveModel.Summary) -> String {
        switch summary.mode {
        case CallHandling.appFirst: SetupCopy.goliveAnswersAppFirst(summary.ringSeconds)
        case CallHandling.aiThenApp: SetupCopy.goliveAnswersAiThenApp
        default: SetupCopy.callsAiFirst
        }
    }
}
