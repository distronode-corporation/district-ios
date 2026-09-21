import SwiftUI

/// What a write came to, as one line under the form.
///
/// ⛔ A SUCCESS AND A FAILURE ARE THE SAME COMPONENT AND NOT THE SAME TONE. Both
/// have to appear in the place the operator is already looking — under the button
/// they pressed — and a green sentence rendered in the failure's register (or the
/// reverse) is how somebody reads "3 deleted, 2 could not be deleted" as done.
///
/// ⚠️ IT NEVER OFFERS THE RETRY ``FailureText`` COMPUTED. On these sheets the
/// retry IS the submit button, which is still on screen and still live; a second
/// one beside it would be two ways to send the same request, and the more
/// dangerous of them would be the one that did not re-check the typed
/// confirmation.
struct SchedulingWritesBNotice: View {
    let state: SchedulingWritesBState

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        switch state {
        case .idle, .working:
            EmptyView()
        case let .done(message):
            line(message, colors.success)
        case let .failed(failure):
            line(failure.message, colors.destructive)
        }
    }

    private func line(_ message: String, _ tint: Color) -> some View {
        Text(message)
            .font(DistrictType.bodySmall)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A validation refusal, which is not a failure and must not be drawn as one.
///
/// ⚠️ NO REQUEST WAS SPENT. "That did not save" would be describing something that
/// never happened; what these say is what to change before trying.
struct SchedulingWritesBRejection: View {
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

/// The muted sentence under a field, carrying a limit or a consequence.
///
/// ⚠️ ITS OWN COMPONENT SO EVERY HINT RESOLVES THE PALETTE THE SAME WAY. The
/// alternative is `DistrictColors.resolve(colorScheme)` repeated at a dozen call
/// sites, which is where somebody eventually writes `.resolve(.light)` and the
/// hint disappears in dark mode.
struct SchedulingWritesBHint: View {
    let text: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(DistrictType.caption)
            .foregroundStyle(DistrictColors.resolve(colorScheme).mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The shell every scheduling write sheet uses: a title, a body, and the two
/// buttons.
///
/// ⛔ NO `NavigationStack`. These are presented from screens that already own one,
/// and a second stack inside a sheet gives a nested bar, a duplicated title and a
/// back gesture that dismisses nothing. The title is a plain heading and the
/// dismissal is the explicit cancel button.
///
/// ⚠️ THE CONFIRM BUTTON IS DISABLED WHILE THE WRITE IS IN FLIGHT AND THE CANCEL
/// BUTTON IS NOT. Leaving a destructive submit live under a spinner is how one tap
/// becomes two requests; leaving the way out live is how somebody escapes a
/// request that has stalled.
struct SchedulingWritesBSheet<Content: View>: View {
    let title: String
    let subtitle: String?
    let cancelLabel: String
    let confirmLabel: String
    var destructive = false
    var confirmEnabled = true
    /// ⚠️ THE CONFIRM BUTTON IS THE ONE ELEMENT EVERY UI TEST ON THIS SURFACE HAS
    /// TO ADDRESS, and it lives inside the shell rather than at the call site — so
    /// the identifier has to be passed in. Optional because a sheet with no test
    /// yet should not have to invent one.
    var confirmIdentifier: String?
    let state: SchedulingWritesBState
    /// ⛔ DECLARED BEFORE THE TWO ACTIONS, AND THE ORDER IS LOAD-BEARING. The
    /// memberwise initialiser follows declaration order, so this puts `content`,
    /// `onCancel` and `onConfirm` last and contiguous — which is what lets a call
    /// site use MULTIPLE TRAILING CLOSURES. One trailing closure beside two
    /// parenthesised ones is a `multiple_closures_with_trailing_closure` violation
    /// on every sheet that uses this shell; all-trailing is not.
    @ViewBuilder let content: Content
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var colors: DistrictColors {
        .resolve(colorScheme)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DistrictSpacing.section) {
                header
                content
                SchedulingWritesBNotice(state: state)
                buttons
            }
            .padding(DistrictSpacing.gutter)
        }
        .background(colors.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DistrictSpacing.hairline) {
            Text(title)
                .font(DistrictType.titleLarge)
                .foregroundStyle(colors.foreground)
                // ⚠️ THE SHEET'S OWN HEADING IS THE HEADER FOR VoiceOver. Without
                // it the first element read is whatever control happens to be
                // first, and on a destructive sheet that is the thing the operator
                // most needs to hear last.
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(DistrictType.bodySmall)
                    .foregroundStyle(colors.mutedForeground)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// ⚠️ NAMED RATHER THAN INLINE IN A TERNARY. `.districtDestructive` resolves
    /// through `ButtonStyle where Self == DistrictButtonStyle`, and a leading-dot
    /// pair inside a ternary at a generic parameter is exactly where that inference
    /// gets fragile.
    private var confirmStyle: DistrictButtonStyle {
        destructive ? .districtDestructive : .districtPrimary
    }

    private var buttons: some View {
        VStack(spacing: DistrictSpacing.tight) {
            Button(confirmLabel, action: onConfirm)
                .buttonStyle(confirmStyle)
                .disabled(!confirmEnabled || state.isWorking)
                .accessibilityIdentifier(confirmIdentifier ?? "")
                // ⛔ NO ⌘↩ ON A DESTRUCTIVE CONFIRM; see ``KeyboardShortcut/districtSubmit``.
                .keyboardShortcut(destructive ? nil : .districtSubmit)
            Button(cancelLabel, action: onCancel)
                .buttonStyle(.districtSecondary)
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity)
    }
}
