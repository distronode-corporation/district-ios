import DistrictData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The new secret: its QR code, the key to type by hand, and the code that confirms it.
///
/// ⛔ NOTHING HERE LOGS, PERSISTS OR SHARES THE SECRET. Copy writes it to this device's
/// pasteboard for two minutes (``TwoStepSecret/copySensitive(_:)``), and Open hands the
/// `otpauth://` link to an authenticator app on this device; there is no share sheet.
struct TwoStepScanCard: View {
    @Bindable var model: TwoStepModel
    let enrollment: TwoStepModel.Enrollment

    @State private var copied = false
    @State private var openFailed = false
    @FocusState private var focused: Bool
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        TwoStepCard {
            DistrictEyebrow(text: TwoStepCopy.scanTitle)
            TwoStepParagraph(text: TwoStepCopy.scanIntro)
            qrCode
            Text(TwoStepCopy.keyLabel)
                .font(DistrictType.labelLarge)
                .foregroundStyle(colors.foreground)
            TwoStepSecretText(text: TwoStepSecret.grouped(enrollment.secret))
                .accessibilityLabel(TwoStepCopy.keyLabel)
                .accessibilityValue(enrollment.secret)
                .accessibilityIdentifier(A11yID.TwoStep.secret)
            Button(copied ? TwoStepCopy.copied : TwoStepCopy.copyKey) {
                TwoStepSecret.copySensitive(enrollment.secret)
                copied = true
            }
            .buttonStyle(.districtSecondary)
            .accessibilityIdentifier(A11yID.TwoStep.copyKey)
            Button(TwoStepCopy.openAuthenticator, action: open)
                .buttonStyle(.districtSecondary)
                .accessibilityIdentifier(A11yID.TwoStep.openAuthenticator)
            if openFailed {
                TwoStepParagraph(text: TwoStepCopy.openFailed)
            }
            TwoStepParagraph(text: TwoStepCopy.codePrompt)
            TextField(MfaCopy.authenticatorPlaceholder, text: $model.totp)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .districtField()
                .focused($focused)
                .disabled(model.busy)
                .onSubmit(confirm)
                .accessibilityIdentifier(A11yID.TwoStep.totp)
            if let failure = model.failure {
                Text(failure)
                    .font(DistrictType.bodySmall)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(Tone.warning.ink(colors))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(A11yID.TwoStep.message)
            }
            Button(TwoStepCopy.confirmButton, action: confirm)
                .buttonStyle(.districtPrimary)
                .disabled(!model.canConfirm)
                .accessibilityIdentifier(A11yID.TwoStep.confirm)
            TwoStepBackButton(model: model)
            TwoStepBusy(busy: model.busy)
        }
    }

    @ViewBuilder
    private var qrCode: some View {
        if let png = enrollment.qrPNG, let image = UIImage(data: png) {
            Image(uiImage: image)
                // ⚠️ NEAREST-NEIGHBOUR: a smoothed QR code blurs its modules and scans worse.
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 220)
                // ⚠️ THE SERVICE DRAWS DARK ON LIGHT: a white quiet zone keeps it scannable in dark mode.
                .padding(DistrictSpacing.tight)
                .background(Color.white, in: RoundedRectangle(cornerRadius: DistrictRadius.control))
                .frame(maxWidth: .infinity)
                .privacySensitive()
                .accessibilityLabel(TwoStepCopy.qrLabel)
                .accessibilityIdentifier(A11yID.TwoStep.qr)
        } else {
            TwoStepParagraph(text: TwoStepCopy.qrUnreadable)
        }
    }

    private func confirm() {
        Task { await model.confirm() }
    }

    private func open() {
        guard let url = URL(string: enrollment.otpauthURI) else {
            openFailed = true
            return
        }
        openURL(url) { accepted in openFailed = !accepted }
    }
}

/// The recovery codes, this once, with Copy all and the warning that they are not shown again.
struct TwoStepCodesCard: View {
    let model: TwoStepModel

    @State private var copied = false
    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        TwoStepCard {
            DistrictEyebrow(text: TwoStepCopy.codesTitle)
            Text(TwoStepCopy.codesWarning)
                .font(DistrictType.bodySmall)
                .foregroundStyle(Tone.warning.ink(colors))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            TwoStepSecretText(text: model.recoveryCodes.joined(separator: "\n"))
                .accessibilityIdentifier(A11yID.TwoStep.codes)
            Button(copied ? TwoStepCopy.copied : TwoStepCopy.copyAll) {
                TwoStepSecret.copySensitive(model.recoveryCodes.joined(separator: "\n"))
                copied = true
            }
            .buttonStyle(.districtSecondary)
            .accessibilityIdentifier(A11yID.TwoStep.copyCodes)
            Button(TwoStepCopy.codesDone) {
                Task { await model.finishRecoveryCodes() }
            }
            .buttonStyle(.districtPrimary)
            .disabled(model.busy)
            .accessibilityIdentifier(A11yID.TwoStep.codesDone)
            TwoStepBusy(busy: model.busy)
        }
    }
}

/// What the two cards do with a secret besides drawing it.
enum TwoStepSecret {
    /// The key in groups of four, as authenticator apps print it. ⚠️ Display only: Copy and
    /// VoiceOver read the key as the service sent it.
    static func grouped(_ secret: String) -> String {
        stride(from: 0, to: secret.count, by: 4).map { start in
            let from = secret.index(secret.startIndex, offsetBy: start)
            let to = secret.index(from, offsetBy: 4, limitedBy: secret.endIndex) ?? secret.endIndex
            return String(secret[from ..< to])
        }.joined(separator: " ")
    }

    /// ⛔ THIS DEVICE ONLY, AND FOR TWO MINUTES: never the universal clipboard, and not left on
    /// the pasteboard for whatever is pasted next week.
    static func copySensitive(_ text: String) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]
        )
    }
}

// ── Pieces shared by the sheet and its cards ─────────────────────────────────

/// A secret in a monospaced, selectable, privacy-sensitive box.
struct TwoStepSecretText: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = DistrictColors.resolve(colorScheme)
        Text(text)
            .font(DistrictType.bodySmall)
            .monospaced()
            .textSelection(.enabled)
            .foregroundStyle(colors.foreground)
            .padding(DistrictSpacing.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.muted, in: RoundedRectangle(cornerRadius: DistrictRadius.control))
            .privacySensitive()
    }
}

struct TwoStepParagraph: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(DistrictType.bodySmall)
            .foregroundStyle(DistrictColors.resolve(colorScheme).foreground)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TwoStepCard<Rows: View>: View {
    private let rows: Rows

    init(@ViewBuilder rows: () -> Rows) {
        self.rows = rows()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.row) {
            rows
        }
        .padding(DistrictSpacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .districtCardSurface()
    }
}

struct TwoStepBackButton: View {
    let model: TwoStepModel

    var body: some View {
        Button(DeleteAccountCopy.back, action: model.back)
            .buttonStyle(.districtGhost)
            .disabled(model.busy)
            .accessibilityIdentifier(A11yID.TwoStep.back)
    }
}

struct TwoStepBusy: View {
    let busy: Bool

    var body: some View {
        if busy {
            ProgressView()
                .frame(maxWidth: .infinity)
        }
    }
}
