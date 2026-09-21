import SwiftUI

/// The shell every write sheet on this surface uses.
///
/// ⛔ NO `NavigationStack` AND NO TOOLBAR, matching `MessagingAccountSheet` and
/// `CreateContactSheet`. `ShellView` registers `navigationDestination(for:)` once
/// per tab; a stack inside a sheet is a second registration waiting to happen, and
/// none of these sheets has anywhere to navigate to.
///
/// ⚠️ A `ScrollView`, ALWAYS. The webhook form is 7 checkboxes plus 22 more, and a
/// `VStack` that overflows on a small phone with Larger Text silently clips its
/// submit button — which is the one control the sheet exists for.
struct SchedulingWriteSheetC<Content: View>: View {
    let title: String
    private let content: Content

    @Environment(\.colorScheme) private var colorScheme

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.row) {
                Text(title)
                    .font(DistrictType.title)
                    .foregroundStyle(colors.foreground)
                content
            }
            .padding(DistrictSpacing.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One sentence about a write, in the tone of what it says.
///
/// ⛔ A FAILURE IS NEVER RENDERED AS AN ABSENCE, which is the rule `FailureText`
/// exists to enforce, and it is why this takes the whole value rather than a
/// `String`: the ACTION decides whether a retry is offered, and a retry offered for
/// a role refusal is worse than none at all.
struct SchedulingWriteFailureLineC: View {
    let failure: FailureText
    var onRetry: (() -> Void)?
    var onDismiss: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(failure.message)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.destructive)
            controls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// ⚠️ RETRY IS DRAWN ONLY FOR `.retry`. `.signIn` is unreachable from the admin
    /// RPC (a 401 collapses to `forbidden` inside `SchedulingAdminError`), so there
    /// is no sign-in control here to go stale.
    private var controls: some View {
        HStack(spacing: DistrictSpacing.tight) {
            if failure.action == .retry, let onRetry {
                Button(SchedulingWriteCopyC.retry, action: onRetry)
                    .buttonStyle(.districtSecondary)
            }
            if let onDismiss {
                Button(SchedulingWriteCopyC.dismiss, action: onDismiss)
                    .buttonStyle(.districtGhost)
            }
        }
    }
}

/// A positive sentence after a write that landed.
struct SchedulingWriteNoticeLineC: View {
    let message: String
    var onDismiss: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(message)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.success)
            if let onDismiss {
                Button(SchedulingWriteCopyC.dismiss, action: onDismiss)
                    .buttonStyle(.districtGhost)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One tick box with an optional badge beside its label.
///
/// ⚠️ A `Toggle` WITH `.switch` RATHER THAN A CHECKBOX, because iOS has no checkbox
/// and `.checkbox` is macOS-only. The semantics a screen reader reports are the
/// same; the shape is the platform's.
struct SchedulingWriteToggleRowC: View {
    let label: String
    let isOn: Binding<Bool>
    var badge: String?
    var enabled = true

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        Toggle(isOn: isOn) {
            HStack(spacing: DistrictSpacing.hairline) {
                Text(label)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.foreground)
                if let badge {
                    Text(badge)
                        .font(DistrictType.labelSmall)
                        .foregroundStyle(Tone.danger.ink(colors))
                        .padding(.horizontal, DistrictSpacing.hairline)
                        .background(
                            Tone.danger.fill(colors),
                            in: RoundedRectangle(cornerRadius: DistrictRadius.badge)
                        )
                }
            }
        }
        .disabled(!enabled)
    }
}

/// A read-only `label: value` line, for the facts a write sheet states and cannot
/// change.
struct SchedulingWriteFactC: View {
    let label: String
    let value: String

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(label)
                .font(DistrictType.labelSmall)
                .foregroundStyle(colors.mutedForeground)
            Text(value)
                .font(DistrictType.bodySmall)
                .foregroundStyle(colors.foreground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
