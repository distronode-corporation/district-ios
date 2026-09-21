import SwiftUI
import UIKit

/// "Create key" — name it, mint it, and read the plaintext once.
///
/// ⛔ THE REVEAL IS A SECOND SHEET PRESENTED FROM `model.minted`, NOT A SECTION OF
/// THIS ONE. `sheet(item:)` is what guarantees the plaintext is dropped the moment
/// the sheet closes: SwiftUI writes nil back through the binding itself, and the
/// setter calls `dismissMinted()`. Rendering it inline would leave it in this
/// view's body for as long as the form stayed up.
///
/// ⚠️ THE FORM SHEET STAYS OPEN BEHIND THE REVEAL. Dismissing this one on a
/// successful mint would tear down the very view presenting the secret.
struct SchedulingAPIKeyCreateSheet: View {
    @Bindable var model: SchedulingAPIKeyCreateModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        SchedulingWriteSheetC(title: SchedulingWriteCopyC.keySheetTitle) {
            Text(SchedulingWriteCopyC.keyNameHint)
                .font(DistrictType.caption)
                .foregroundStyle(colors.mutedForeground)
            SettingsField(
                label: SchedulingWriteCopyC.keyNameLabel,
                text: $model.name,
                enabled: !model.busy
            )
            .accessibilityIdentifier(A11yID.SchedulingDeveloperWrites.keyNameField)
            if let nameError = model.nameError {
                Text(nameError)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.destructive)
            }
            if let failure = model.failure {
                SchedulingWriteFailureLineC(
                    failure: failure,
                    onRetry: submit,
                    onDismiss: model.dismissFailure
                )
            }
            buttons
        }
        .sheet(item: mintedBinding) { minted in
            SchedulingAPIKeyRevealSheet(minted: minted, model: model)
        }
    }

    /// ⚠️ A WRITE-THROUGH BINDING OVER A `private(set)`, so the ONLY thing the view
    /// can do to it is clear it — which is what a sheet dismissal means and the only
    /// transition this state has.
    private var mintedBinding: Binding<SchedulingAPIKeyMintedC?> {
        Binding(
            get: { model.minted },
            set: { value in
                if value == nil {
                    model.dismissMinted()
                }
            }
        )
    }

    private var buttons: some View {
        HStack(spacing: DistrictSpacing.tight) {
            Button(SchedulingWriteCopyC.cancel) { dismiss() }
                .buttonStyle(.districtGhost)
                .disabled(model.busy)
            Button(
                model.busy ? SchedulingWriteCopyC.keyCreating : SchedulingWriteCopyC.keyCreate,
                action: submit
            )
            .buttonStyle(.districtPrimary)
            .disabled(!model.canSubmit)
            .accessibilityIdentifier(A11yID.SchedulingDeveloperWrites.keyCreate)
        }
    }

    private func submit() {
        Task { await model.create() }
    }
}

/// The one and only sight of a minted key.
///
/// ⛔ NOTHING HERE LOGS, PERSISTS OR SHARES THE VALUE. The copy button writes it to
/// the pasteboard because that is the point of the sheet; there is no share sheet,
/// no snippet and no "email it to me", each of which would put a live credential
/// somewhere nobody can revoke it from.
struct SchedulingAPIKeyRevealSheet: View {
    let minted: SchedulingAPIKeyMintedC
    let model: SchedulingAPIKeyCreateModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        SchedulingWriteSheetC(title: SchedulingWriteCopyC.keyRevealTitle(minted.name)) {
            Text(SchedulingWriteCopyC.keyRevealWarning)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
            Text(minted.key)
                .font(DistrictType.bodySmall)
                .monospaced()
                .textSelection(.enabled)
                .foregroundStyle(colors.foreground)
                .padding(DistrictSpacing.tight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(colors.muted, in: RoundedRectangle(cornerRadius: DistrictRadius.control))
                .accessibilityIdentifier(A11yID.SchedulingDeveloperWrites.keyRevealed)
            HStack(spacing: DistrictSpacing.tight) {
                Button(
                    model.copied ? SchedulingWriteCopyC.keyCopied : SchedulingWriteCopyC.keyCopyAction,
                    action: copy
                )
                .buttonStyle(.districtSecondary)
                .accessibilityIdentifier(A11yID.SchedulingDeveloperWrites.keyCopy)
                Button(SchedulingWriteCopyC.keyDone) { dismiss() }
                    .buttonStyle(.districtPrimary)
            }
        }
    }

    private func copy() {
        UIPasteboard.general.string = minted.key
        model.markCopied()
    }
}
