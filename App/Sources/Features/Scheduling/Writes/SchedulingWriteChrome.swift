import SwiftUI

/// The parts every scheduling write sheet draws the same way.
///
/// ⛔ ONE LABELLED FIELD, ONE FAILURE STRIP AND ONE NOTICE STRIP, SHARED, because
/// the alternative is six sheets that each decide how a refusal looks. The rule
/// they enforce between them is ``FailureText``'s: a failure is a sentence in the
/// destructive colour, a success is a sentence in the muted one, and neither is
/// ever rendered as an absence of content.
///
/// ⛔ NO `NavigationStack` ANYWHERE IN THIS FILE OR ITS CALLERS. A stack inside a
/// presented sheet is a second `Route.self` destination registration waiting to
/// happen; these sheets have nowhere to navigate to, and their buttons live in
/// their own bodies.
struct SchedulingWriteField<Content: View>: View {
    let label: String
    var hint: String?
    var error: String?
    @ViewBuilder let content: Content

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(label)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            content
            if let hint, error == nil {
                Text(hint)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.mutedForeground)
            }
            if let error {
                Text(error)
                    .font(DistrictType.caption)
                    .foregroundStyle(colors.destructive)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A refused write, or a refused form.
///
/// ⚠️ IT DRAWS THE SENTENCE AND NOT THE OFFER. ``FailureText/action`` decides
/// whether a retry is honest; these sheets keep their own Save button live, so
/// re-pressing IS the retry and a second button beside it would be two ways to do
/// one thing.
struct SchedulingWriteFailureStrip: View {
    let message: String?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let message {
            Text(message)
                .font(DistrictType.caption)
                .foregroundStyle(DistrictColors.resolve(colorScheme).destructive)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// What just saved.
struct SchedulingWriteNotice: View {
    let message: String?
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let message {
            HStack(spacing: DistrictSpacing.tight) {
                Text(message)
                    .font(DistrictType.caption)
                    .foregroundStyle(DistrictColors.resolve(colorScheme).mutedForeground)
                Spacer(minLength: 0)
                Button("Dismiss") {
                    onDismiss()
                }
                .buttonStyle(.districtGhost)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Cancel beside the one button that spends a request.
struct SchedulingWriteButtons: View {
    let saveTitle: String
    let saving: Bool
    var enabled = true
    let saveIdentifier: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: DistrictSpacing.tight) {
            Button(SchedulingWriteCopy.cancel) {
                onCancel()
            }
            .buttonStyle(.districtGhost)
            .disabled(saving)
            .accessibilityIdentifier(A11yID.SchedulingWrites.editorCancel)
            .keyboardShortcut(.cancelAction)
            Button(saving ? SchedulingWriteCopy.saving : saveTitle) {
                onSave()
            }
            .buttonStyle(.districtPrimary)
            .disabled(saving || !enabled)
            .accessibilityIdentifier(saveIdentifier)
            .keyboardShortcut(.districtSubmit)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
