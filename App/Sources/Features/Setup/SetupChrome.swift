import DistrictModel
import SwiftUI

/// The pages the wizard opens in a sheet for what stays on the web, and the pieces its
/// steps share.
///
/// ⛔ AN IN-APP SAFARI SHEET, NEVER `openURL`: every destination is under
/// `/dashboard/district/*`, a path this app claims, so the system would route it straight
/// back here (see ``FinishSetupCard``). The wizard reads its state again when the sheet closes.
enum SetupHandOff {
    /// The web wizard, which opens by itself on the dashboard home at its first open step:
    /// buying a number (and the plan behind it).
    case setup
    /// Studio, Skills: the email sender name and reply-to, and the transfer number.
    case skills
    /// Studio, Integrations: a calendar's sign-in.
    case integrations

    private var path: String {
        switch self {
        case .setup: AppLinkResolver.pathPrefix
        case .skills: AppLinkResolver.pathPrefix + "/studio/skills"
        case .integrations: AppLinkResolver.pathPrefix + "/studio/integrations"
        }
    }

    /// ⚠️ DERIVED FROM THE CONTAINER'S BASE URL, never a literal, so a staging build opens
    /// staging; and nil off HTTPS, where `SFSafariViewController` traps.
    func destination(baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme == "https" else { return nil }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

/// A labelled text field with its error under it.
///
/// ⚠️ THE LABEL IS THE FIELD'S ACCESSIBILITY NAME AND THE ERROR ITS VALUE'S HINT, so VoiceOver
/// reads "Business name, text field, Enter your business name." rather than a red line alone.
struct SetupField: View {
    let label: String
    @Binding var text: String
    var hint: String?
    var error: String?
    var placeholder: String?
    var keyboard: UIKeyboardType = .default
    var content: UITextContentType?
    var multiline = false
    var identifier: String?

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(label)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
                .accessibilityHidden(true)
            field
                .keyboardType(keyboard)
                .textContentType(content)
                .autocorrectionDisabled(keyboard != .default)
                .textInputAutocapitalization(keyboard == .default ? .sentences : .never)
                .districtField()
                .accessibilityLabel(label)
                .accessibilityHint(error ?? hint ?? "")
                .accessibilityIdentifier(identifier ?? "")
            if let hint {
                Text(hint)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
            if let error {
                SetupErrorLine(text: error)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var field: some View {
        let prompt = placeholder.map { Text($0).foregroundStyle(colors.mutedForeground) } ?? .noPlaceholder
        if multiline {
            TextField(label, text: $text, prompt: prompt, axis: .vertical)
                .lineLimit(2 ... 6)
        } else {
            TextField(label, text: $text, prompt: prompt)
        }
    }
}

/// A sentence in the destructive chip ink, for a field's or a step's refusal.
struct SetupErrorLine: View {
    let text: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(DistrictType.caption)
            .foregroundStyle(DistrictColors.resolve(colorScheme).destructiveChipInk)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A quiet sentence: a lead, a hint, a status.
struct SetupNote: View {
    let text: String
    var font = DistrictType.bodySmall

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(DistrictColors.resolve(colorScheme).mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One option of a single choice, as a full-width row whose tick is a trait.
///
/// ⛔ `.isSelected`, NOT A GLYPH NAME, is what VoiceOver reads as "selected" (the rule
/// ``CallHandlingView`` states for its own rows).
struct SetupChoiceRow: View {
    let title: String
    var detail: String?
    let selected: Bool
    var enabled = true
    let identifier: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: DistrictSpacing.tight) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(DistrictType.title)
                    .foregroundStyle(selected ? colors.district : colors.mutedForeground)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
                    Text(title)
                        .font(DistrictType.bodySmall)
                        .foregroundStyle(colors.foreground)
                    if let detail {
                        Text(detail)
                            .font(DistrictType.caption)
                            .foregroundStyle(colors.mutedForeground)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, DistrictSpacing.hairline)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier(identifier)
    }
}

/// A button that opens one of the web's pages in a sheet.
///
/// ⚠️ DRAWN DISABLED, NOT HIDDEN, WHEN THE BUILD'S HOST IS NOT HTTPS (a loopback test server):
/// the step still says where its rest is done, and nothing can open a sheet that would trap.
struct SetupHandOffButton: View {
    let title: String
    let page: SetupHandOff
    let baseURL: URL
    let identifier: String
    let open: (URL) -> Void

    var body: some View {
        let url = page.destination(baseURL: baseURL)
        Button(title) {
            if let url {
                open(url)
            }
        }
        .buttonStyle(.districtSecondary)
        .disabled(url == nil)
        .accessibilityIdentifier(identifier)
    }
}

/// A primary action that says it is working while it is.
struct SetupPrimaryButton: View {
    let title: String
    let busy: Bool
    var enabled = true
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(busy ? SetupCopy.saving : title, action: action)
            .buttonStyle(.districtPrimary)
            .disabled(busy || !enabled)
            .accessibilityIdentifier(identifier)
    }
}
