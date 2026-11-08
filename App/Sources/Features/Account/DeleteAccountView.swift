import DistrictData
import SwiftUI

/// The account deletion sheet: what is deleted and kept, a fresh re-authentication, the typed
/// email, then the deletion. See ``DeleteAccountModel``.
///
/// ⚠️ A SHEET WITH ITS OWN `NavigationStack`, NOT A ``Route``. The flow is modal and has no
/// place in a back stack: a restored stack must never land a person on its last step.
///
/// ⛔ AFTER A DELETION THE SHEET DOES NOT CLOSE ITSELF. ``SessionModel/finishDeletedAccount(
/// externalErasurePending:)`` signs out locally, and ``RootView`` swaps the shell, this sheet
/// with it, for the sign-in screen, which says the account was deleted.
struct DeleteAccountView: View {
    @State private var model: DeleteAccountModel
    @FocusState private var focused: Field?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private enum Field {
        case password, code, email
    }

    init(container: AppContainer, session: SessionModel) {
        let repository = NativeReauthRepository(client: container.api)
        let sheet = ReauthSheetController(
            baseURL: container.baseURL,
            repository: repository,
            deviceId: container.deviceId
        )
        _model = State(initialValue: DeleteAccountModel(
            repository: repository,
            sso: { provider in await sheet.reauthenticate(provider: provider, action: .deleteAccount) },
            deleted: { pending in await session.finishDeletedAccount(externalErasurePending: pending) }
        ))
    }

    /// For previews and tests: a model built elsewhere.
    init(model: DeleteAccountModel) {
        _model = State(initialValue: model)
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
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
            .navigationTitle(DeleteAccountCopy.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(DeleteAccountCopy.cancel) { dismiss() }
                        .disabled(model.busy)
                        .accessibilityIdentifier(A11yID.DeleteAccount.cancel)
                }
            }
        }
        // ⚠️ NO SWIPE AWAY MID-REQUEST: the answer would land on a sheet nobody sees.
        .interactiveDismissDisabled(model.busy)
        .accessibilityIdentifier(A11yID.DeleteAccount.sheet)
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .explain:
            warningCard
            failureLine
            methodsCard
        case let .password(needsCode):
            failureLine
            passwordCard(needsCode: needsCode)
        case .confirm:
            failureLine
            confirmCard
        }
    }

    // ── What is deleted ──────────────────────────────────────────────────────

    private var warningCard: some View {
        card {
            Text(DeleteAccountCopy.cannotBeUndone)
                .font(DistrictType.title)
                .foregroundStyle(colors.destructive)
            paragraph(DeleteAccountCopy.whatIsDeleted)
            paragraph(DeleteAccountCopy.subscriptionsCancelled)
            paragraph(DeleteAccountCopy.whatIsKept)
        }
    }

    // ── Confirm it is you ────────────────────────────────────────────────────

    private var methodsCard: some View {
        card {
            DistrictEyebrow(text: DeleteAccountCopy.confirmItIsYou)
            paragraph(DeleteAccountCopy.confirmIntro)
            ForEach(ReauthProvider.allCases, id: \.self) { provider in
                Button(DeleteAccountCopy.continueWith(provider.displayName)) {
                    Task { await model.reauthenticate(with: provider) }
                }
                .buttonStyle(.districtSecondary)
                .disabled(model.busy)
                .accessibilityIdentifier(A11yID.DeleteAccount.provider(provider.rawValue))
            }
            Button(DeleteAccountCopy.usePassword) {
                model.usePassword()
                focused = .password
            }
            .buttonStyle(.districtSecondary)
            .disabled(model.busy)
            .accessibilityIdentifier(A11yID.DeleteAccount.usePassword)
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
                .accessibilityIdentifier(A11yID.DeleteAccount.password)
            if needsCode {
                paragraph(MfaCopy.authenticatorPrompt)
                TextField(MfaCopy.authenticatorPlaceholder, text: $model.code)
                    // ⚠️ ONE FIELD FOR BOTH KINDS: the service takes an authenticator code or a
                    // recovery code in the same place.
                    .textContentType(.oneTimeCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .districtField()
                    .focused($focused, equals: .code)
                    .disabled(model.busy)
                    .onSubmit(submitPassword)
                    .accessibilityIdentifier(A11yID.DeleteAccount.code)
            }
            Button(DeleteAccountCopy.continueButton, action: submitPassword)
                .buttonStyle(.districtPrimary)
                .disabled(!model.canSubmitPassword)
                .accessibilityIdentifier(A11yID.DeleteAccount.passwordContinue)
            Button(DeleteAccountCopy.back, action: model.back)
                .buttonStyle(.districtGhost)
                .disabled(model.busy)
                .accessibilityIdentifier(A11yID.DeleteAccount.back)
            busyIndicator
        }
    }

    // ── The last step ────────────────────────────────────────────────────────

    private var confirmCard: some View {
        card {
            DistrictEyebrow(text: DeleteAccountCopy.lastStep)
            paragraph(DeleteAccountCopy.typeEmail)
            TextField(DeleteAccountCopy.emailLabel, text: $model.confirmation)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .districtField()
                .focused($focused, equals: .email)
                .disabled(model.busy)
                .accessibilityIdentifier(A11yID.DeleteAccount.email)
            Button(model.busy ? DeleteAccountCopy.deleting : DeleteAccountCopy.submit) {
                Task { await model.delete() }
            }
            .buttonStyle(.districtDestructive)
            .disabled(!model.canDelete)
            .accessibilityIdentifier(A11yID.DeleteAccount.submit)
            busyIndicator
        }
        .onAppear { focused = .email }
    }

    // ── Pieces ───────────────────────────────────────────────────────────────

    @ViewBuilder
    private var failureLine: some View {
        if let failure = model.failure {
            VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                if let title = failure.title {
                    Text(title)
                        .font(DistrictType.labelLarge)
                }
                Text(failure.message)
                    .font(DistrictType.bodySmall)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Tone.warning.ink(colors))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(A11yID.DeleteAccount.message)
        }
    }

    @ViewBuilder
    private var busyIndicator: some View {
        if model.busy {
            ProgressView()
                .frame(maxWidth: .infinity)
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(DistrictType.bodySmall)
            .foregroundStyle(colors.foreground)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card(@ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            rows()
        }
        .padding(DistrictSpacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .districtCardSurface()
    }

    private func submitPassword() {
        Task { await model.submitPassword() }
    }
}
