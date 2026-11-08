import DistrictData
import SwiftUI

/// The two-step verification sheet: whether it is on, turning it on with an authenticator app,
/// the recovery codes once, and turning it off. See ``TwoStepModel``.
///
/// ⚠️ A SHEET WITH ITS OWN `NavigationStack`, NOT A ``Route``, as ``DeleteAccountView``: the
/// flow is modal, and a restored back stack must never land on a step that held a secret.
///
/// ⛔ THE SECRET AND THE CODES ARE COVERED WHENEVER THE APP IS NOT ACTIVE, so the app
/// switcher's snapshot never shows them, and are marked privacy-sensitive. Leaving the sheet
/// drops them (``TwoStepModel/leave()``).
struct TwoStepView: View {
    @State private var model: TwoStepModel
    @FocusState private var focused: Field?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    private enum Field {
        case password, code
    }

    init(container: AppContainer) {
        let reauth = NativeReauthRepository(client: container.api)
        let sheet = ReauthSheetController(
            baseURL: container.baseURL,
            repository: reauth,
            deviceId: container.deviceId
        )
        _model = State(initialValue: TwoStepModel(
            settings: TwoStepSettingsRepository(client: container.api),
            reauth: reauth,
            sso: { provider in await sheet.reauthenticate(provider: provider, action: .twoFactorChange) }
        ))
    }

    /// For previews and tests: a model built elsewhere.
    init(model: TwoStepModel) {
        _model = State(initialValue: model)
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    /// ⚠️ ONLY THE STEPS THAT HOLD A CREDENTIAL ARE COVERED: the overview has nothing to hide.
    private var holdsSecret: Bool {
        model.step == .scan || model.step == .recoveryCodes
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                    content
                }
                .padding(DistrictSpacing.gutter)
                .districtReadableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay {
                if holdsSecret, scenePhase != .active {
                    cover
                }
            }
            .navigationTitle(TwoStepCopy.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(TwoStepCopy.close) { dismiss() }
                        .disabled(model.busy || model.step == .recoveryCodes)
                        .accessibilityIdentifier(A11yID.TwoStep.close)
                }
            }
        }
        // ⚠️ NO SWIPE AWAY MID-REQUEST, NOR PAST THE CODES: they are never shown again.
        .interactiveDismissDisabled(model.busy || model.step == .recoveryCodes)
        .task { await model.load() }
        .onDisappear { model.leave() }
        .accessibilityIdentifier(A11yID.TwoStep.sheet)
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .loading:
            card { SkeletonBlock(height: 72) }
        case .loadFailed:
            messageLines
            Button(TwoStepCopy.retry) { Task { await model.load() } }
                .buttonStyle(.districtSecondary)
                .disabled(model.busy)
                .accessibilityIdentifier(A11yID.TwoStep.retry)
        case .overview:
            messageLines
            statusCard
        case let .reauth(intent):
            messageLines
            methodsCard(intent)
        case let .password(_, needsCode):
            messageLines
            passwordCard(needsCode: needsCode)
        case .scan:
            // ⚠️ NO MESSAGE LINE ABOVE THE CARD HERE: the card is taller than a phone, so a refusal
            // drawn above it is off screen when Turn on is tapped. The card draws it by the field.
            if let enrollment = model.enrollment {
                TwoStepScanCard(model: model, enrollment: enrollment)
            }
        case .recoveryCodes:
            TwoStepCodesCard(model: model)
        }
    }

    // ── On or off ────────────────────────────────────────────────────────────

    @ViewBuilder
    private var statusCard: some View {
        if let status = model.status {
            card {
                Text(status.enrolled ? TwoStepCopy.statusOn : TwoStepCopy.statusOff)
                    .font(DistrictType.title)
                    .foregroundStyle(colors.foreground)
                    .accessibilityIdentifier(A11yID.TwoStep.status)
                if status.enrolled {
                    if let since = status.enrolledAt {
                        paragraph(TwoStepCopy.onSince(WireDate.display(since)))
                    }
                    paragraph(status.backupCodesRemaining == 0
                        ? TwoStepCopy.codesNone
                        : TwoStepCopy.codesLeft(status.backupCodesRemaining))
                    if model.signsInWithoutPassword {
                        paragraph(TwoStepCopy.noPasswordNote)
                    }
                    Button(TwoStepCopy.turnOff) { model.begin(.turnOff) }
                        .buttonStyle(.districtDestructive)
                        .disabled(model.busy)
                        .accessibilityIdentifier(A11yID.TwoStep.turnOff)
                } else {
                    paragraph(TwoStepCopy.offExplain)
                    Button(TwoStepCopy.turnOn) { model.begin(.turnOn) }
                        .buttonStyle(.districtPrimary)
                        .disabled(model.busy)
                        .accessibilityIdentifier(A11yID.TwoStep.turnOn)
                }
                busyIndicator
            }
        }
    }

    // ── Confirm it is you ────────────────────────────────────────────────────

    private func methodsCard(_ intent: TwoStepModel.Intent) -> some View {
        card {
            DistrictEyebrow(text: DeleteAccountCopy.confirmItIsYou)
            paragraph(intent == .turnOn ? TwoStepCopy.reauthIntroOn : TwoStepCopy.reauthIntroOff)
            ForEach(ReauthProvider.allCases, id: \.self) { provider in
                Button(DeleteAccountCopy.continueWith(provider.displayName)) {
                    Task { await model.reauthenticate(with: provider) }
                }
                .buttonStyle(.districtSecondary)
                .disabled(model.busy)
                .accessibilityIdentifier(A11yID.TwoStep.provider(provider.rawValue))
            }
            Button(DeleteAccountCopy.usePassword) {
                model.usePassword()
                focused = .password
            }
            .buttonStyle(.districtSecondary)
            .disabled(model.busy)
            .accessibilityIdentifier(A11yID.TwoStep.usePassword)
            backButton
            busyIndicator
        }
    }

    private func passwordCard(needsCode: Bool) -> some View {
        card {
            DistrictEyebrow(text: DeleteAccountCopy.confirmItIsYou)
            SecureField(DeleteAccountCopy.passwordLabel, text: $model.password)
                .textContentType(.password)
                .districtField()
                .focused($focused, equals: .password)
                .disabled(model.busy)
                .submitLabel(needsCode ? .next : .continue)
                .onSubmit {
                    if needsCode {
                        focused = .code
                    } else {
                        submitPassword()
                    }
                }
                .accessibilityIdentifier(A11yID.TwoStep.password)
            if needsCode {
                paragraph(MfaCopy.authenticatorPrompt)
                TextField(MfaCopy.authenticatorPlaceholder, text: $model.code)
                    // ⚠️ ONE FIELD FOR BOTH KINDS, as on the deletion sheet: an authenticator
                    // code or a recovery code.
                    .textContentType(.oneTimeCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .districtField()
                    .focused($focused, equals: .code)
                    .disabled(model.busy)
                    .onSubmit(submitPassword)
                    .accessibilityIdentifier(A11yID.TwoStep.code)
            }
            Button(DeleteAccountCopy.continueButton, action: submitPassword)
                .buttonStyle(.districtPrimary)
                .disabled(!model.canSubmitPassword)
                .accessibilityIdentifier(A11yID.TwoStep.passwordContinue)
            backButton
            busyIndicator
        }
    }

    // ── Pieces ───────────────────────────────────────────────────────────────

    /// The notice of the last change, then the failure, each as one line.
    @ViewBuilder
    private var messageLines: some View {
        if let notice = model.notice {
            Text(notice)
                .font(DistrictType.bodySmall)
                .foregroundStyle(Tone.success.ink(colors))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(A11yID.TwoStep.notice)
        }
        if let failure = model.failure {
            Text(failure)
                .font(DistrictType.bodySmall)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(Tone.warning.ink(colors))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(A11yID.TwoStep.message)
        }
    }

    private var cover: some View {
        ZStack {
            colors.background
            Image(systemName: "lock.fill")
                .font(DistrictType.title)
                .foregroundStyle(colors.mutedForeground)
                .accessibilityHidden(true)
        }
        .ignoresSafeArea()
    }

    private var backButton: some View {
        TwoStepBackButton(model: model)
    }

    private var busyIndicator: some View {
        TwoStepBusy(busy: model.busy)
    }

    private func paragraph(_ text: String) -> some View {
        TwoStepParagraph(text: text)
    }

    private func card(@ViewBuilder rows: () -> some View) -> some View {
        TwoStepCard(rows: rows)
    }

    private func submitPassword() {
        Task { await model.submitPassword() }
    }

    private func confirm() {
        Task { await model.confirm() }
    }
}
